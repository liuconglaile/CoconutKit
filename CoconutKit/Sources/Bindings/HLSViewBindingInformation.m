//
//  HLSViewBindingInformation.m
//  CoconutKit
//
//  Created by Samuel Défago on 18.06.13.
//  Copyright (c) 2013 Samuel Défago. All rights reserved.
//

#import "HLSViewBindingInformation.h"

#import "HLSLogger.h"
#import "HLSMAKVONotificationCenter.h"
#import "HLSTransformer.h"
#import "NSBundle+HLSExtensions.h"
#import "NSError+HLSExtensions.h"
#import "NSObject+HLSExtensions.h"
#import "NSString+HLSExtensions.h"
#import "UIView+HLSViewBinding.h"
#import "UIView+HLSViewBindingImplementation.h"

#import <objc/runtime.h>

@interface HLSViewBindingInformation ()

@property (nonatomic, weak) id object;
@property (nonatomic, weak) id objectTarget;
@property (nonatomic, strong) NSString *keyPath;
@property (nonatomic, strong) NSString *transformerName;
@property (nonatomic, weak) UIView *view;

@property (nonatomic, weak) id transformationTarget;
@property (nonatomic, assign) SEL transformationSelector;
@property (nonatomic, strong) NSObject<HLSTransformer> *transformer;

@property (nonatomic, weak) id<HLSBindingDelegate> delegate;

@property (nonatomic, assign) HLSViewBindingStatus status;
@property (nonatomic, strong) NSString *statusDescription;

@property (nonatomic, assign, getter=isSynchronized) BOOL synchronized;

// Used to prevent calls to checks / update methods when we are simply updating a view. Depending on how view update
// is performed, we namely could end up triggering an update which would yield to a view updated, and therefore
// to an infinite call chain
@property (nonatomic, assign, getter=isUpdatingView) BOOL updatingView;

@end

@implementation HLSViewBindingInformation

#pragma mark Object creation and destruction

- (instancetype)initWithObject:(id)object keyPath:(NSString *)keyPath transformerName:(NSString *)transformerName view:(UIView *)view
{
    if (self = [super init]) {
        if (! [keyPath isFilled] || ! view) {
            HLSLoggerError(@"Binding requires at least a keypath and a view");
            return nil;
        }
        
        if (! view.bindingSupported) {
            HLSLoggerError(@"The view does not support bindings");
            return nil;
        }
        
        self.object = object;
        self.keyPath = keyPath;
        self.transformerName = transformerName;
        self.view = view;
        self.status = HLSViewBindingStatusUnverified;
        self.statusDescription = @"The binding has not been verified yet";
    }
    return self;
}

- (void)dealloc
{
    // Unregister KVO
    self.objectTarget = nil;
}

#pragma mark Accessors and mutators

- (id)value
{
    // Lazily check and fill binding information
    if (self.status != HLSViewBindingStatusValid) {
        self.status = [self verifyBindingInformation];
        if (self.status != HLSViewBindingStatusValid) {
            return nil;
        }
    }
            
    id value = [self.objectTarget valueForKeyPath:self.keyPath];
    return [self transformValue:value];
}

- (id)rawValue
{
    @try {
        return [self.objectTarget valueForKeyPath:self.keyPath];
    }
    @catch (NSException *exception) {
        if ([exception.name isEqualToString:NSUndefinedKeyException]) {
            return nil;
        }
        else {
            @throw;
        }
    }
}

- (void)setObjectTarget:(id)objectTarget
{
    if (_objectTarget && self.synchronized) {
        [_objectTarget removeObserver:self keyPath:self.keyPath];
        
        self.synchronized = NO;
    }
    
    _objectTarget = objectTarget;
    
    // KVO bug: Doing KVO on key paths containing keypath operators (which cannot be used with KVO) and catching the exception leads to retaining the
    // observer (though KVO itself neither retains the observer nor its observee). Catch such key paths before
    if (objectTarget && [self.keyPath rangeOfString:@"@"].length == 0) {
        [objectTarget addObserver:self keyPath:self.keyPath options:NSKeyValueObservingOptionNew block:^(HLSMAKVONotification *notification) {
            [self updateView];
        }];
        
        self.synchronized = YES;
    }
}

#pragma mark Updating the view

- (void)updateView
{
    self.updatingView = YES;
    [self.view performSelector:@selector(updateViewWithValue:) withObject:[self value]];
    self.updatingView = NO;
}

#pragma mark Checking and updating values (these operations notify the delegate about their status)

- (BOOL)convertTransformedValue:(id)transformedValue toValue:(id *)pValue withError:(NSError **)pError
{
    // Skip when triggered by view update implementations
    if (self.updatingView) {
        return YES;
    }
    
    if (self.transformer) {
        BOOL success = YES;
        id value = nil;
        
        NSError *error = nil;
        NSError *detailedError = nil;
        
        if ([self.transformer respondsToSelector:@selector(getObject:fromObject:error:)]) {
            success = [self.transformer getObject:&value fromObject:transformedValue error:&detailedError];
        }
        else {
            detailedError = [NSError errorWithDomain:CoconutKitErrorDomain
                                                code:HLSErrorTransformationError
                                localizedDescription:CoconutKitLocalizedString(@"No reverse transformation is available", nil)];
            success = NO;
        }
        
        if (success) {
            if ([self.delegate respondsToSelector:@selector(view:transformationDidSucceedForObject:keyPath:)]) {
                [self.delegate view:self.view transformationDidSucceedForObject:self.objectTarget keyPath:self.keyPath];
            }
            
            if (pValue) {
                *pValue = value;
            }
        }
        else {
            error = [NSError errorWithDomain:CoconutKitErrorDomain
                                        code:HLSErrorTransformationError
                        localizedDescription:NSLocalizedString(@"Incorrect format", nil)];
            [error setUnderlyingError:detailedError];
            
            if ([self.delegate respondsToSelector:@selector(view:transformationDidFailForObject:keyPath:withError:)]) {
                [self.delegate view:self.view transformationDidFailForObject:self.objectTarget keyPath:self.keyPath withError:error];
            }
            
            if (pError) {
                *pError = error;
            }
        }
        
        return success;
    }
    else {
        if (pValue) {
            *pValue = transformedValue;
        }
        
        return YES;
    }
}

- (BOOL)checkValue:(id)value withError:(NSError **)pError
{
    // Skip when triggered by view update implementations
    if (self.updatingView) {
        return YES;
    }
    
    // TODO: Implement call to -check method as well, since cleaner syntax
    
    NSError *error = nil;
    if ([self.objectTarget validateValue:&value forKeyPath:self.keyPath error:&error]) {
        if ([self.delegate respondsToSelector:@selector(view:checkDidSucceedForObject:keyPath:)]) {
            [self.delegate view:self.view checkDidSucceedForObject:self.objectTarget keyPath:self.keyPath];
        }
        return YES;
    }
    else {
        if ([self.delegate respondsToSelector:@selector(view:checkDidFailForObject:keyPath:withError:)]) {
            [self.delegate view:self.view checkDidFailForObject:self.objectTarget keyPath:self.keyPath withError:error];
        }
        
        if (pError) {
            *pError = error;
        }
        
        return NO;
    }
}

- (BOOL)updateWithValue:(id)value error:(NSError **)pError
{
    // Skip when triggered by view update implementations
    if (self.updatingView) {
        return YES;
    }
    
    @try {
        [self.objectTarget setValue:value forKeyPath:self.keyPath];
    }
    @catch (NSException *exception) {
        if ([exception.name isEqualToString:NSUndefinedKeyException]) {
            NSError *error = [NSError errorWithDomain:CoconutKitErrorDomain
                                                 code:HLSErrorUpdateError
                                 localizedDescription:CoconutKitLocalizedString(@"The value could not be updated", nil)];
            
            if ([self.delegate respondsToSelector:@selector(view:updateDidFailForObject:keyPath:withError:)]) {
                [self.delegate view:self.view updateDidFailForObject:self.objectTarget keyPath:self.keyPath withError:error];
            }
            
            if (pError) {
                *pError = error;
            }
            
            HLSLoggerError(@"Cannot update object %@ with value %@ for key path %@: %@", self.objectTarget, value, self.keyPath, exception);
            return NO;
        }
        else {
            @throw;
        }
    }
    
    if ([self.delegate respondsToSelector:@selector(view:updateDidSucceedForObject:keyPath:)]) {
        [self.delegate view:self.view updateDidSucceedForObject:self.objectTarget keyPath:self.keyPath];
    }
    
    // Force a new binding verification (the value might have been nil, i.e. the information could not be verified, or
    // might have been set to nil)
    self.status = [self verifyBindingInformation];
    
    return YES;
}

#pragma mark Binding

- (HLSViewBindingStatus)verifyBindingInformation
{
    // Just to visually check whether unnecessary verifications are made
    HLSLoggerDebug(@"Verifying binding information for %@", self);
    
    // An object has been provided. Check that the keypath is valid for it
    id objectTarget = nil;
    if (self.object) {
        @try {
            [self.object valueForKeyPath:self.keyPath];
        }
        @catch (NSException *exception) {
            if ([exception.name isEqualToString:NSUndefinedKeyException]) {
                self.statusDescription = @"The specified keypath is invalid for the bound object";
                return HLSViewBindingStatusInvalid;
            }
            else {
                @throw;
            }
        }
        
        objectTarget = self.object;
    }
    // No object provided. Walk along the responder chain to find a responder matching the keypath (might be nil)
    else {
        objectTarget = [HLSViewBindingInformation bindingTargetForKeyPath:self.keyPath view:self.view];
    }
    
    if (! objectTarget) {
        self.statusDescription = @"No meaningful object target was found along the responder chain for the specified keypath (stopping at view controller boundaries)";
        return HLSViewBindingStatusInvalid;
    }
    self.objectTarget = objectTarget;
    
    // No need to check for exceptions here, the keypath is here guaranteed to be valid for the object
    id value = [self.objectTarget valueForKeyPath:self.keyPath];
    
    // Transformer lookup
    if ([self.transformerName isFilled] && ! self.transformer) {
        __block id transformationTarget = nil;
        __block SEL transformationSelector = NULL;

        // Check whether the transformer is a class method +[ClassName methodName]
        // Regex: ^\s*\+\s*\[(\w*)\s*(\w*)\]\s*$
        NSString *pattern = @"^\\s*\\+\\s*\\[(\\w*)\\s*(\\w*)\\]\\s*$";
        NSRegularExpression *classMethodRegularExpression = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                                                      options:0
                                                                                                        error:NULL];
        
        [classMethodRegularExpression enumerateMatchesInString:self.transformerName options:0 range:NSMakeRange(0, [self.transformerName length]) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
            // Extract capture group information
            NSString *className = [self.transformerName substringWithRange:[result rangeAtIndex:1]];
            NSString *methodName = [self.transformerName substringWithRange:[result rangeAtIndex:2]];
            
            // Check
            Class class = NSClassFromString(className);
            if (! class) {
                self.statusDescription = [NSString stringWithFormat:@"The specified global transformer points to an invalid class '%@'", className];
                return;
            }
            
            SEL selector = NSSelectorFromString(methodName);
            if (! class_getClassMethod(class, selector)) {
                self.statusDescription = [NSString stringWithFormat:@"The specified global transformer method '%@' does not exist for the class '%@'", methodName, className];
                return;
            }
            
            transformationTarget = class;
            transformationSelector = selector;
        }];
        
        // No class method transformer found yet
        if (! transformationTarget) {
            // Perform instance method lookup. First validate the method name
            // Regex: ^\s*(\w*)\s*$
            __block NSString *methodName = nil;
            NSString *pattern = @"^\\s*(\\w*)\\s*$";
            NSRegularExpression *methodNameRegularExpression = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                                                         options:0
                                                                                                           error:NULL];
            [methodNameRegularExpression enumerateMatchesInString:self.transformerName options:0 range:NSMakeRange(0, [self.transformerName length]) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
                methodName = [self.transformerName substringWithRange:[result rangeAtIndex:1]];
            }];
            
            if ([methodName isFilled]) {
                transformationSelector = NSSelectorFromString(methodName);
            }
            
            if (! transformationSelector) {
                self.statusDescription = @"The transformer is not a valid method name";
                return HLSViewBindingStatusInvalid;
            }
            
            // Look along the responder chain first (most specific)
            transformationTarget = [HLSViewBindingInformation bindingTargetForSelector:transformationSelector view:self.view];
            if (! transformationTarget) {
                // Look for an instance method on the object
                if ([self.objectTarget respondsToSelector:transformationSelector]) {
                    transformationTarget = self.objectTarget;
                }
                // Look for a class method on the object class itself (most generic)
                else if ([[self.objectTarget class] respondsToSelector:transformationSelector]) {
                    transformationTarget = [self.objectTarget class];
                }
                else {
                    self.statusDescription = @"The specified transformer is neither a valid global transformer, nor could be resolved along the responder chain (stopping at view controller boundaries)";
                    return HLSViewBindingStatusInvalid;
                }
            }
        }
        
        self.transformer = [self transformerFromTransformationTarget:transformationTarget transformationSelector:transformationSelector];
        if (! self.transformer) {
            self.statusDescription = [NSString stringWithFormat:@"Unsupported transformer. Must be an HLSTransformer, NSFormatter or NSValueTransformer instance"];
            return HLSViewBindingStatusInvalid;
        }
        
        self.transformationTarget = transformationTarget;
        self.transformationSelector = transformationSelector;
        
        // Observe transformer updates, reload cached transformer and update view accordingly
        [self.transformationTarget addObserver:self keyPath:NSStringFromSelector(self.transformationSelector) options:NSKeyValueObservingOptionNew block:^(HLSMAKVONotification *notification) {
            self.transformer = [self transformerFromTransformationTarget:self.transformationTarget transformationSelector:self.transformationSelector];
            [self updateView];
        }];
    }
    
    // Locate the binding delegate, if any
    if (! self.delegate) {
        self.delegate = [HLSViewBindingInformation delegateForView:self.view];
    }
    
    id displayedValue = [self transformValue:value];
    
    // We cannot cache binding information if we cannot check the type of the value to be displayed for compatibility. Does not change
    // the status, a later check is required
    if (! displayedValue) {
        self.statusDescription = @"The value returned by the keypath is nil, its type cannot therefore be checked for compatibility yet";
        return HLSViewBindingStatusUnverified;
    }
    
    if (! [self canDisplayValue:displayedValue]) {
        if (self.transformer) {
            self.statusDescription = [NSString stringWithFormat:@"The transformer must return one of the following supported types: %@", [self supportedBindingClassesString]];
        }
        else {
            self.statusDescription = [NSString stringWithFormat:@"The keypath must return one of the following supported types: %@. Fix the return type "
                                     "or use a transformer", [self supportedBindingClassesString]];
        }
        return HLSViewBindingStatusInvalid;
    }
    
    self.statusDescription = @"The binding information is correct";
    return HLSViewBindingStatusValid;
}

- (id<HLSTransformer>)transformerFromTransformationTarget:(id)transformationTarget transformationSelector:(SEL)transformationSelector
{
    // Cannot use -performSelector here since the signature is not explicitly visible in the call for ARC to perform
    // correct memory management
    id (*methodImp)(id, SEL) = (id (*)(id, SEL))[transformationTarget methodForSelector:transformationSelector];
    id transformer = methodImp(transformationTarget, transformationSelector);
    
    if ([transformer conformsToProtocol:@protocol(HLSTransformer)]) {
        return transformer;
    }
    else if ([transformer isKindOfClass:[NSFormatter class]]) {
        return [HLSBlockTransformer blockTransformerFromFormatter:transformer];
    }
    else if ([transformer isKindOfClass:[NSValueTransformer class]]) {
        return [HLSBlockTransformer blockTransformerFromValueTransformer:transformer];
    }
    else {
        return nil;
    }
}

#pragma mark Type checking

- (NSArray *)supportedBindingClasses
{
    Class viewClass = [self.view class];
    
    if ([viewClass respondsToSelector:@selector(supportedBindingClasses)]) {
        return [viewClass supportedBindingClasses];
    }
    else {
        return @[[NSString class]];
    }
}

- (NSString *)supportedBindingClassesString
{
    NSArray *supportedBindingClasses = [self supportedBindingClasses];
    NSMutableArray *classNames = [NSMutableArray array];
    for (Class supportedBindingClass in supportedBindingClasses) {
        [classNames addObject:NSStringFromClass(supportedBindingClass)];
    }
    return [classNames componentsJoinedByString:@", "];
}

- (BOOL)canDisplayValue:(id)value
{
    NSArray *supportedBindingClasses = [self supportedBindingClasses];
    for (Class supportedBindingClass in supportedBindingClasses) {
        if ([value isKindOfClass:supportedBindingClass]) {
            return YES;
        }
    }
    
    return NO;
}

#pragma mark Transformation

- (id)transformValue:(id)value
{
    return self.transformer ? [self.transformer transformObject:value] : value;
}

#pragma mark Context binding lookup

// Always start, not with the view, but with its next responder. Binding namely makes sense with a parent context
// (not in the context of the bound view itself). Moreover, this avoids collisions between the keypath to bind and
// view properties bearing the same name (e.g. a property called 'text' bound to a text field would be trapped
// otherwise be resolved on the text field itself)
+ (id<HLSBindingDelegate>)delegateForView:(UIView *)view
{
    UIResponder *responder = view.nextResponder;
    while (responder) {
        if ([responder conformsToProtocol:@protocol(HLSBindingDelegate)]) {
            return (id<HLSBindingDelegate>)responder;
        }
        
        // Does not get higher than the receiver parent view controller, which defines the binding context
        if ([responder isKindOfClass:[UIViewController class]]) {
            return nil;
        }
        
        responder = responder.nextResponder;
    }
    return nil;
}

// Locate the target which implements the specified method. Stops at view controller boundaries
+ (id)bindingTargetForSelector:(SEL)selector view:(UIView *)view
{
    UIResponder *responder = view.nextResponder;
    while (responder) {
        // Instance method lookup first
        if ([responder respondsToSelector:selector]) {
            return responder;
        }
        
        // Class method lookup
        Class responderClass = [responder class];
        if ([responderClass respondsToSelector:selector]) {
            return responderClass;
        }
        
        // Does not get higher than the receiver parent view controller, which defines the binding context
        if ([responder isKindOfClass:[UIViewController class]]) {
            return nil;
        }
        
        responder = responder.nextResponder;
    }
    return nil;
}

+ (id)bindingTargetForKeyPath:(NSString *)keyPath view:(UIView *)view
{
    UIResponder *responder = view.nextResponder;
    while (responder) {
        @try {
            // Will throw an exception unless the keypath is valid
            [responder valueForKeyPath:keyPath];
            return responder;
        }
        @catch (NSException *exception) {
            if ([exception.name isEqualToString:NSUndefinedKeyException]) {
                // Does not get higher than the receiver parent view controller, which defines the binding context
                if ([responder isKindOfClass:[UIViewController class]]) {
                    return nil;
                }
                
                responder = responder.nextResponder;
            }
            else {
                @throw;
            }
        }
    }
    return nil;
}

#pragma mark Description

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p; object: %@; objectTarget: %@; keyPath: %@; transformerName: %@; transformationTarget: %@; transformationSelector:%@>",
            [self class],
            self,
            self.object,
            self.objectTarget,
            self.keyPath,
            self.transformerName,
            self.transformationTarget,
            NSStringFromSelector(self.transformationSelector)];
}

@end

@implementation HLSViewBindingInformation (ConvenienceMethods)

- (BOOL)checkDisplayedValue:(id)displayedValue withError:(NSError **)pError
{
    // Skip when triggered by view update implementations
    if (self.updatingView) {
        return YES;
    }
    
    id value = nil;
    NSError *error = nil;
    if ([self convertTransformedValue:displayedValue toValue:&value withError:&error]
        && [self checkValue:value withError:&error]) {
        return YES;
    }
    
    if (pError) {
        *pError = error;
    }
    
    return NO;
}

- (BOOL)updateModelWithDisplayedValue:(id)displayedValue error:(NSError **)pError
{
    // Skip when triggered by view update implementations
    if (self.updatingView) {
        return YES;
    }
    
    id value = nil;
    NSError *error = nil;
    if ([self convertTransformedValue:displayedValue toValue:&value withError:&error]
        && [self updateWithValue:value error:&error]) {
        return YES;
    }
    
    if (pError) {
        *pError = error;
    }
    
    return NO;
}

- (BOOL)checkAndUpdateModelWithDisplayedValue:(id)displayedValue error:(NSError **)pError
{
    // Skip when triggered by view update implementations
    if (self.updatingView) {
        return YES;
    }
    
    id value = nil;
    BOOL success = YES;
    NSError *error = nil;
    if ([self convertTransformedValue:displayedValue toValue:&value withError:&error]) {
        NSError *checkError = nil;
        if (! [self checkValue:value withError:&checkError]) {
            success = NO;
            [NSError combineError:checkError withError:&error];
        }
        
        NSError *updateError = nil;
        if (! [self updateWithValue:value error:&updateError]) {
            success = NO;
            [NSError combineError:updateError withError:&error];
        }
    }
    
    if (pError) {
        *pError = error;
    }
    
    return success;
}

@end

#pragma mark Functions

NSString *HLSViewBindingNameForStatus(HLSViewBindingStatus status)
{
    static NSDictionary *s_statusToNameMap = nil;
    static dispatch_once_t s_onceToken;
    dispatch_once(&s_onceToken, ^{
        s_statusToNameMap = @{ @(HLSViewBindingStatusUnverified) : @"unverified",
                               @(HLSViewBindingStatusValid) : @"valid",
                               @(HLSViewBindingStatusInvalid) : @"invalid" };
    });
    return [s_statusToNameMap objectForKey:@(status)];
}

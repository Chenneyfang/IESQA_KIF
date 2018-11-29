//
//  UIAutomationHelper.m
//  KIF
//
//  Created by Joe Masilotti on 12/1/14.
//
//

#import "UIAutomationHelper.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import "UIApplication-KIFAdditions.h"
static BOOL CURRENT_TYPE = YES;
@interface UIAXElement : NSObject
- (BOOL)isValid;

@end

@interface UIAElement : NSObject <NSCopying>
- (void)tap;
- (void)tapWithOptions:(NSDictionary *)options;
- (NSNumber *)pid;
- (UIAXElement *)uiaxElement;
- (id)mainWindow;
- (id)navigationBar;
@end

@interface UIAElementArray : NSArray
- (id)c:(id)predicate;
@end

@interface UIAAlert : UIAElement
- (NSArray *)buttons;
- (BOOL)isValid;
- (BOOL)isVisible;
@end

@interface UIAApplication : UIAElement
- (UIAAlert *)alert;
- (NSString *)name;
- (id)appItemScrollView;
@end

@interface UIATarget : UIAElement
+ (UIATarget *)localTarget;
- (UIAApplication *)frontMostApp;
- (void)deactivateAppForDuration:(NSNumber *)duration;
@end

@interface UIAElementNil : UIAElement

@end


@implementation UIAutomationHelper

static UIAApplication * (*frontMostAppIMP)(id, SEL);
static id (*firstWithPredicateIMP)(id, SEL, id);

static UIAApplication * KIF_frontMostApp(id self, SEL _cmd)
{
    UIAApplication *frontMostApp = frontMostAppIMP(self, _cmd);
    if (![frontMostApp name] && [@(getpid()) isEqual:[frontMostApp pid]]) {
        NSBundle *mainBundle = [NSBundle mainBundle];
        NSString *appName = [mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [mainBundle objectForInfoDictionaryKey:@"CFBundleName"];
        [frontMostApp setValue:appName forKey:@"name"];
    }
    return frontMostApp;
}

static id KIF_firstWithPredicate(id self, SEL _cmd, id predicate)
{
    NSArray *callStackSymbols = [NSThread callStackSymbols];
    if (callStackSymbols.count > 1 && [callStackSymbols[1] containsString:@"-[UIATarget reactivateApp]"]) {
        id firstWithPredicate = firstWithPredicateIMP(self, _cmd, predicate);
        // -[UIATarget reactivateApp] was not rewritten for the new iOS 9 app switcher
        return [firstWithPredicate isValid] ? firstWithPredicate : [[[[UIAutomationHelper sharedHelper] target] frontMostApp] appItemScrollView];
    } else {
        return firstWithPredicateIMP(self, _cmd, predicate);
    }
}

static void FixReactivateApp(void)
{
    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    if ([processInfo respondsToSelector:@selector(isOperatingSystemAtLeastVersion:)] && [processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){9, 0, 0}]) {
        // Workaround bug in iOS 9: https://github.com/kif-framework/KIF/issues/703
        Method frontMostApp = class_getInstanceMethod(objc_lookUpClass("UIATarget"), @selector(frontMostApp));
        frontMostAppIMP = (__typeof__(frontMostAppIMP))method_getImplementation(frontMostApp);
        method_setImplementation(frontMostApp, (IMP)KIF_frontMostApp);
        
        Method firstWithPredicate = class_getInstanceMethod(objc_lookUpClass("UIAElementArray"), @selector(firstWithPredicate:));
        firstWithPredicateIMP = (__typeof__(firstWithPredicateIMP))method_getImplementation(firstWithPredicate);
        method_setImplementation(firstWithPredicate, (IMP)KIF_firstWithPredicate);
    }
}

+ (UIAutomationHelper *)sharedHelper
{
    static dispatch_once_t once;
    static UIAutomationHelper *sharedHelper = nil;
    dispatch_once(&once, ^{
        sharedHelper = [[self alloc] init];
        [sharedHelper linkAutomationFramework];
    });
    return sharedHelper;
}

+ (BOOL)acknowledgeSystemAlert {
    return [[self sharedHelper] acknowledgeSystemAlert];
}

+ (BOOL)acknowledgeSystemAlertWithIndex:(NSUInteger)index {
    return [[self sharedHelper] acknowledgeSystemAlertWithIndex:index];
}

+ (void)deactivateAppForDuration:(NSNumber *)duration {
    CURRENT_TYPE = YES;
    [[self sharedHelper] deactivateAppForDuration:duration];
}

+ (void)deactivateOtherAppAndGoBackForDuration:(NSNumber *)duration {
    CURRENT_TYPE = NO;
    [[self sharedHelper] deactivateAppForDuration:duration];
}

+ (void)tapAppstoreCancle{
    [[self sharedHelper] tapAppstoreCancle];
}

+ (void)tapScreenAtPoint:(CGPoint )point{
    [[self sharedHelper] tapScreenAtPoint:point];
}

+ (BOOL)checkShowingAppstoreOnSimulator{
    return [[self sharedHelper] checkShowingAppstoreOnSimulator];
}

- (BOOL)checkShowingAppstoreOnSimulator{
    UIAApplication *application = [[self target] frontMostApp];
    if (application) {
        //        if (![application.mainWindow navigationBar]) {
        //            return NO;
        //        }
        NSArray * array = nil;
        @try {
            array = [[application.mainWindow navigationBar] buttons];
        } @catch (NSException *exception) {
            return NO;
        } @finally {
            
        }
        //NSArray * array = [[application.mainWindow navigationBar] buttons];
        if ([array count] > 0) {
            id obj = array[0];
            if ([[obj name] isEqualToString:@"取消"]) {
                return YES;
            }
        }
    }
    return NO;
}

- (void)tapAppstoreCancle{
    [[[self target] frontMostApp] tapWithOptions:@{@"tapOffset": @{@"x": @(.1), @"y": @(.05)}}];
}

- (BOOL)acknowledgeSystemAlert {
    UIAAlert* alert = [[self target] frontMostApp].alert;
    // Even though `acknowledgeSystemAlertWithIndex:` checks the index, we have to have
    // an additional check here to ensure that when `alert.buttons.count` is 0, subtracting one doesn't cause a wrap-around (2^63 - 1).
    if (alert.buttons.count > 0) {
        return [self acknowledgeSystemAlertWithIndex:alert.buttons.count - 1];
    }
    return NO;
}

- (void)tapScreenAtPoint:(CGPoint )point{
    CGRect rect = [[UIScreen mainScreen] bounds];
    NSNumber * offsetX = [NSNumber numberWithDouble:point.x / rect.size.width];
    NSNumber * offsetY = [NSNumber numberWithDouble:point.y / rect.size.height];
    [[[self target] frontMostApp] tapWithOptions:@{@"tapOffset": @{@"x": offsetX, @"y": offsetY}}];
}

// Inspired by:  https://github.com/jamesjn/KIF/tree/acknowledge-location-alert
- (BOOL)acknowledgeSystemAlertWithIndex:(NSUInteger)index {
    UIAApplication *application = [[self target] frontMostApp];
    UIAAlert *alert = application.alert;
    BOOL isIndexInRange = index < alert.buttons.count;
    if (![alert isKindOfClass:[self nilElementClass]] && [self _alertIsValidAndVisible:alert] && isIndexInRange) {
        [alert.buttons[index] tap];
        while ([self _alertIsValidAndVisible:alert]) {
            // Wait for button press to complete.
            KIFRunLoopRunInModeRelativeToAnimationSpeed(UIApplicationCurrentRunMode, 0.1, false);
        }
        // Wait for alert dismissial animation.
        KIFRunLoopRunInModeRelativeToAnimationSpeed(UIApplicationCurrentRunMode, 0.4, false);
        return YES;
    }
    return NO;
}


- (void)IQdeactivateAppForDuration:(NSNumber *)duration {
    @try {
        [[self target] deactivateAppForDuration:duration];
    }
    @catch(NSException *e) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-variable"
        NSOperatingSystemVersion iOS11 = {11, 0, 0};
        NSAssert([NSProcessInfo instancesRespondToSelector:@selector(isOperatingSystemAtLeastVersion:)] && [[NSProcessInfo new] isOperatingSystemAtLeastVersion:iOS11], @"The issue of resuming from SpringBoard is only known to occur on iOS 11+.");
        NSAssert([[[[self target] frontMostApp] name] isEqual:@"SpringBoard"], @"If reactivation is failing, the app is likely still open to SpringBoard.");
        
        // Tap slightly above the middle of the screen, otherwise it doesn't resume on an iPad Pro
        if (CURRENT_TYPE) {
            [[[self target] frontMostApp] tapWithOptions:@{@"tapOffset": @{@"x": @(.36), @"y": @(.36)}}];
        }
        else{
            [[[self target] frontMostApp] tapWithOptions:@{@"tapOffset": @{@"x": @(.05), @"y": @(.36)}}];
        }
        
        // Wait for app to foreground
        CFRunLoopRunInMode(UIApplicationCurrentRunMode, 0.1, false);
        
        // Ensure our test app has returned to being the front most app
        //        NSString *testAppName = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleDisplayName"];
        //        NSAssert([[[[self target] frontMostApp] name] isEqual:testAppName], @"After tapping, the main app should be relaunched.");
#pragma clang diagnostic pop
    }
}

- (void)IQdeactivateAppWithRetryForDuration:(NSNumber *)duration {
    int max_count = 3;
    while (max_count > 0) {
        [self IQdeactivateAppForDuration:duration];
        NSString *testAppName = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleDisplayName"];
        if ([[[[self target] frontMostApp] name] isEqual:testAppName]) {
            break;
        }
        max_count --;
    }
    if (max_count >=3) {
        NSAssert(NO, @"restart 3 times failed!");
    }
}



- (void)deactivateAppForDuration:(NSNumber *)duration {
    @try {
        [[self target] deactivateAppForDuration:duration];
    }
    @catch(NSException *e) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-variable"
        NSOperatingSystemVersion iOS11 = {11, 0, 0};
        NSAssert([NSProcessInfo instancesRespondToSelector:@selector(isOperatingSystemAtLeastVersion:)] && [[NSProcessInfo new] isOperatingSystemAtLeastVersion:iOS11], @"The issue of resuming from SpringBoard is only known to occur on iOS 11+.");
        NSAssert([[[[self target] frontMostApp] name] isEqual:@"SpringBoard"], @"If reactivation is failing, the app is likely still open to SpringBoard.");
        
        // Tap slightly above the middle of the screen, otherwise it doesn't resume on an iPad Pro
        if (CURRENT_TYPE) {
            [[[self target] frontMostApp] tapWithOptions:@{@"tapOffset": @{@"x": @(.36), @"y": @(.36)}}];
        }
        else{
            [[[self target] frontMostApp] tapWithOptions:@{@"tapOffset": @{@"x": @(.05), @"y": @(.36)}}];
        }
        
        // Wait for app to foreground
        CFRunLoopRunInMode(UIApplicationCurrentRunMode, 0.1, false);
        
        // Ensure our test app has returned to being the front most app
        NSString *testAppName = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleDisplayName"];
        NSAssert([[[[self target] frontMostApp] name] isEqual:testAppName], @"After tapping, the main app should be relaunched.");
#pragma clang diagnostic pop
    }
}

#pragma mark - Private

- (BOOL)_alertIsValidAndVisible:(UIAAlert *)alert;
{
    // Ignore alert if in process; calling isVisible on alert in process causes a signal such as EXC_BAD_INSTRUCTION (not a catchable exception)
    UIAApplication *application = [[self target] frontMostApp];
    if ([@(getpid()) isEqual:[application pid]])
        return false;
    
    // [alert isValid] is returning an __NSCFBoolean which is really hard to compare against.
    // Translate the __NSCFBoolean into a vanilla BOOL.
    // See https://www.bignerdranch.com/blog/bools-sharp-corners/ for more details.
    
    BOOL visible = NO;
    
    @try {
        visible = [[alert valueForKeyPath:@"isVisible"] boolValue];
    }
    @catch (NSException *exception) { }
    
    return ([alert isValid] && visible);
}

- (void)linkAutomationFramework {
    dlopen([@"/Developer/Library/PrivateFrameworks/UIAutomation.framework/UIAutomation" fileSystemRepresentation], RTLD_LOCAL);
    FixReactivateApp();
    
    // Keep trying until the accessibility server starts up (it takes a little while on iOS 7)
    UIATarget *target = nil;
    while (!target) {
        @try {
            target = [self target];
        }
        @catch (NSException *exception) { }
        @finally { }
    }
}

- (UIATarget *)target {
    return [NSClassFromString(@"UIATarget") localTarget];
}

- (Class)nilElementClass {
    return NSClassFromString(@"UIAElementNil");
}

@end


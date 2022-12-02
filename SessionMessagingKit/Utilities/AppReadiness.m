//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "AppReadiness.h"
#import "AppContext.h"

NS_ASSUME_NONNULL_BEGIN

@interface AppReadiness ()

@property (atomic) BOOL isAppReady;

@property (nonatomic) NSMutableArray<AppReadyBlock> *appWillBecomeReadyBlocks;
@property (nonatomic) NSMutableArray<AppReadyBlock> *appDidBecomeReadyBlocks;

@end

#pragma mark -

@implementation AppReadiness

+ (instancetype)sharedManager
{
    static AppReadiness *sharedMyManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedMyManager = [[self alloc] initDefault];
    });
    return sharedMyManager;
}

- (instancetype)initDefault
{
    self = [super init];

    if (!self) {
        return self;
    }

    self.appWillBecomeReadyBlocks = [NSMutableArray new];
    self.appDidBecomeReadyBlocks = [NSMutableArray new];

    return self;
}

+ (BOOL)isAppReady
{
    return [self.sharedManager isAppReady];
}

+ (void)runNowOrWhenAppWillBecomeReady:(AppReadyBlock)block
{
    if ([NSThread isMainThread]) {
        [self.sharedManager runNowOrWhenAppWillBecomeReady:block];
    }
    else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.sharedManager runNowOrWhenAppWillBecomeReady:block];
        });
    }
}

- (void)runNowOrWhenAppWillBecomeReady:(AppReadyBlock)block
{
    if (CurrentAppContext().isRunningTests) {
        // We don't need to do any "on app ready" work in the tests.
        return;
    }

    if (self.isAppReady) {
        block();
        return;
    }

    [self.appWillBecomeReadyBlocks addObject:block];
}

+ (void)runNowOrWhenAppDidBecomeReady:(AppReadyBlock)block
{
    if ([NSThread isMainThread]) {
        [self.sharedManager runNowOrWhenAppDidBecomeReady:block];
    }
    else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.sharedManager runNowOrWhenAppDidBecomeReady:block];
        });
    }
}

- (void)runNowOrWhenAppDidBecomeReady:(AppReadyBlock)block
{
    if (CurrentAppContext().isRunningTests) {
        // We don't need to do any "on app ready" work in the tests.
        return;
    }

    if (self.isAppReady) {
        block();
        return;
    }

    [self.appDidBecomeReadyBlocks addObject:block];
}

+ (void)setAppIsReady
{
    [self.sharedManager setAppIsReady];
}

- (void)setAppIsReady
{
    self.isAppReady = YES;

    [self runAppReadyBlocks];
}

- (void)runAppReadyBlocks
{
    NSArray<AppReadyBlock> *appWillBecomeReadyBlocks = [self.appWillBecomeReadyBlocks copy];
    [self.appWillBecomeReadyBlocks removeAllObjects];
    NSArray<AppReadyBlock> *appDidBecomeReadyBlocks = [self.appDidBecomeReadyBlocks copy];
    [self.appDidBecomeReadyBlocks removeAllObjects];

    // We invoke the _will become_ blocks before the _did become_ blocks.
    for (AppReadyBlock block in appWillBecomeReadyBlocks) {
        block();
    }
    for (AppReadyBlock block in appDidBecomeReadyBlocks) {
        block();
    }
}

@end

NS_ASSUME_NONNULL_END

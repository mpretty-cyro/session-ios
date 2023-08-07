//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import <SessionUtilitiesKit/AppContext.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const ReportedApplicationStateDidChangeNotification;

@interface MainAppContext : NSObject <AppContext>

- (instancetype)init;

@end

NS_ASSUME_NONNULL_END

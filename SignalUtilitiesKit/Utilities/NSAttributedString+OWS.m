//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "NSAttributedString+OWS.h"
#import <SessionUtilitiesKit/AppContext.h>
#import <SignalCoreKit/OWSAsserts.h>

NS_ASSUME_NONNULL_BEGIN

@implementation NSAttributedString (OWS)

- (NSAttributedString *)rtlSafeAppend:(NSString *)text attributes:(NSDictionary *)attributes
{
    OWSAssertDebug(text);
    OWSAssertDebug(attributes);

    NSAttributedString *substring = [[NSAttributedString alloc] initWithString:text attributes:attributes];
    return [self rtlSafeAppend:substring];
}

- (NSAttributedString *)rtlSafeAppend:(NSAttributedString *)string
{
    OWSAssertDebug(string);

    NSMutableAttributedString *result = [NSMutableAttributedString new];
    if (CurrentAppContext().isRTL) {
        [result appendAttributedString:string];
        [result appendAttributedString:self];
    } else {
        [result appendAttributedString:self];
        [result appendAttributedString:string];
    }
    return [result copy];
}

@end

NS_ASSUME_NONNULL_END

// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

#import "NetworkLayerViewController.h"

#import "Session-Swift.h"
#import <SignalCoreKit/NSString+OWS.h>

#import <SignalUtilitiesKit/UIColor+OWS.h>
#import <SignalUtilitiesKit/SignalUtilitiesKit-Swift.h>
#import <SessionUtilitiesKit/NSString+SSK.h>
#import <SignalUtilitiesKit/SignalUtilitiesKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

@implementation NetworkLayerViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    [self updateTableContents];
    
    [LKViewControllerUtilities setUpDefaultSessionStyleForVC:self withTitle:@"Network Layer" customBackButton:NO];
    self.tableView.backgroundColor = UIColor.clearColor;
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    [self updateTableContents];
}

#pragma mark - Table Contents

- (void)updateTableContents
{
    OWSTableContents *contents = [OWSTableContents new];

    __weak NetworkLayerViewController *weakSelf = self;
    
    OWSTableSection *section = [OWSTableSection new];

    NSString *currentValue = [SSKNetworkLayer currentLayer];
    NSArray *allLayers = [SSKNetworkLayer allLayers];
    NSArray *allLayerNames = [SSKNetworkLayer allLayerNames];
    
    for (NSString *name in allLayerNames) {
        NSUInteger index = [allLayerNames indexOfObject:name];
        NSString *layerValue = allLayers[index];

        [section addItem:[OWSTableItem
                             itemWithCustomCellBlock:^{
                                 UITableViewCell *cell = [OWSTableItem newCell];
                                 cell.tintColor = LKColors.accent;
                                 [[cell textLabel] setText:name];
                                 if ([layerValue isEqualToString:currentValue]) {
                                     cell.accessoryType = UITableViewCellAccessoryCheckmark;
                                 }
                                 return cell;
                             }
                             actionBlock:^{
                                 [weakSelf setNetworkLayer:layerValue];
                             }]];
    }
    [contents addSection:section];

    self.contents = contents;
}

- (void)setNetworkLayer:(NSString *)value
{
    [SSKNetworkLayer setLayerTo:value];
    [self.navigationController popViewControllerAnimated:YES];
}

@end

NS_ASSUME_NONNULL_END

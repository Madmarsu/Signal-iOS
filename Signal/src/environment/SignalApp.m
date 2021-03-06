//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "SignalApp.h"
#import "ConversationViewController.h"
#import "HomeViewController.h"
#import "Signal-Swift.h"
#import <SignalMessaging/DebugLogger.h>
#import <SignalMessaging/Environment.h>
#import <SignalServiceKit/OWSPrimaryStorage.h>
#import <SignalServiceKit/TSContactThread.h>
#import <SignalServiceKit/TSGroupThread.h>
#import <SignalServiceKit/Threading.h>

NS_ASSUME_NONNULL_BEGIN

@interface SignalApp ()

@property (nonatomic) OWSWebRTCCallMessageHandler *callMessageHandler;
@property (nonatomic) CallService *callService;
@property (nonatomic) OutboundCallInitiator *outboundCallInitiator;
@property (nonatomic) OWSMessageFetcherJob *messageFetcherJob;
@property (nonatomic) NotificationsManager *notificationsManager;
@property (nonatomic) AccountManager *accountManager;

@end

#pragma mark -

@implementation SignalApp

+ (instancetype)sharedApp
{
    static SignalApp *sharedApp = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedApp = [[self alloc] initDefault];
    });
    return sharedApp;
}

- (instancetype)initDefault
{
    self = [super init];

    if (!self) {
        return self;
    }

    OWSSingletonAssert();

    return self;
}

#pragma mark - Singletons

- (OWSWebRTCCallMessageHandler *)callMessageHandler
{
    @synchronized(self)
    {
        if (!_callMessageHandler) {
            _callMessageHandler =
                [[OWSWebRTCCallMessageHandler alloc] initWithAccountManager:self.accountManager
                                                                callService:self.callService
                                                              messageSender:Environment.shared.messageSender];
        }
    }

    return _callMessageHandler;
}

- (CallService *)callService
{
    @synchronized(self)
    {
        if (!_callService) {
            OWSAssertDebug(self.accountManager);
            OWSAssertDebug(Environment.shared.contactsManager);
            OWSAssertDebug(Environment.shared.messageSender);
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didChangeCallLoggingPreference:) name:OWSPreferencesCallLoggingDidChangeNotification object:nil];

            _callService = [[CallService alloc] initWithAccountManager:self.accountManager
                                                       contactsManager:Environment.shared.contactsManager
                                                         messageSender:Environment.shared.messageSender
                                                  notificationsAdapter:[OWSCallNotificationsAdapter new]];
        }
    }

    return _callService;
}

- (CallUIAdapter *)callUIAdapter
{
    return self.callService.callUIAdapter;
}

- (OutboundCallInitiator *)outboundCallInitiator
{
    @synchronized(self)
    {
        if (!_outboundCallInitiator) {
            OWSAssertDebug(Environment.shared.contactsManager);
            OWSAssertDebug(Environment.shared.contactsUpdater);
            _outboundCallInitiator =
                [[OutboundCallInitiator alloc] initWithContactsManager:Environment.shared.contactsManager
                                                       contactsUpdater:Environment.shared.contactsUpdater];
        }
    }

    return _outboundCallInitiator;
}

- (OWSMessageFetcherJob *)messageFetcherJob
{
    @synchronized(self)
    {
        if (!_messageFetcherJob) {
            _messageFetcherJob =
                [[OWSMessageFetcherJob alloc] initWithMessageReceiver:[OWSMessageReceiver sharedInstance]
                                                       networkManager:Environment.shared.networkManager
                                                        signalService:[OWSSignalService sharedInstance]];
        }
    }
    return _messageFetcherJob;
}

- (NotificationsManager *)notificationsManager
{
    @synchronized(self)
    {
        if (!_notificationsManager) {
            _notificationsManager = [NotificationsManager new];
        }
    }

    return _notificationsManager;
}

- (AccountManager *)accountManager
{
    @synchronized(self)
    {
        if (!_accountManager) {
            _accountManager = [[AccountManager alloc] initWithTextSecureAccountManager:[TSAccountManager sharedInstance]
                                                                           preferences:Environment.shared.preferences];
        }
    }

    return _accountManager;
}

#pragma mark - View Convenience Methods

- (void)presentConversationForRecipientId:(NSString *)recipientId animated:(BOOL)isAnimated
{
    [self presentConversationForRecipientId:recipientId action:ConversationViewActionNone animated:(BOOL)isAnimated];
}

- (void)presentConversationForRecipientId:(NSString *)recipientId
                                   action:(ConversationViewAction)action
                                 animated:(BOOL)isAnimated
{
    __block TSThread *thread = nil;
    [OWSPrimaryStorage.dbReadWriteConnection
        readWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
            thread = [TSContactThread getOrCreateThreadWithContactId:recipientId transaction:transaction];
        }];
    [self presentConversationForThread:thread action:action animated:(BOOL)isAnimated];
}

- (void)presentConversationForThreadId:(NSString *)threadId animated:(BOOL)isAnimated
{
    OWSAssertDebug(threadId.length > 0);

    TSThread *thread = [TSThread fetchObjectWithUniqueID:threadId];
    if (thread == nil) {
        OWSFailDebug(@"unable to find thread with id: %@", threadId);
        return;
    }

    [self presentConversationForThread:thread animated:isAnimated];
}

- (void)presentConversationForThread:(TSThread *)thread animated:(BOOL)isAnimated
{
    [self presentConversationForThread:thread action:ConversationViewActionNone animated:isAnimated];
}

- (void)presentConversationForThread:(TSThread *)thread action:(ConversationViewAction)action animated:(BOOL)isAnimated
{
    [self presentConversationForThread:thread action:action focusMessageId:nil animated:isAnimated];
}

- (void)presentConversationForThread:(TSThread *)thread
                              action:(ConversationViewAction)action
                      focusMessageId:(nullable NSString *)focusMessageId
                            animated:(BOOL)isAnimated
{
    OWSAssertIsOnMainThread();

    OWSLogInfo(@"");

    if (!thread) {
        OWSFailDebug(@"Can't present nil thread.");
        return;
    }

    DispatchMainThreadSafe(^{
        UIViewController *frontmostVC = [[UIApplication sharedApplication] frontmostViewController];

        if ([frontmostVC isKindOfClass:[ConversationViewController class]]) {
            ConversationViewController *conversationVC = (ConversationViewController *)frontmostVC;
            if ([conversationVC.thread.uniqueId isEqualToString:thread.uniqueId]) {
                [conversationVC popKeyBoard];
                return;
            }
        }

        [self.homeViewController presentThread:thread action:action focusMessageId:focusMessageId animated:isAnimated];
    });
}

- (void)didChangeCallLoggingPreference:(NSNotification *)notitication
{
    [self.callService createCallUIAdapter];
}

#pragma mark - Methods

+ (void)resetAppData
{
    // This _should_ be wiped out below.
    OWSLogError(@"");
    [DDLog flushLog];

    [OWSStorage resetAllStorage];
    [OWSUserProfile resetProfileStorage];
    [Environment.shared.preferences clear];

    [self clearAllNotifications];

    [DebugLogger.sharedLogger wipeLogs];
    exit(0);
}

+ (void)clearAllNotifications
{
    OWSLogInfo(@"clearAllNotifications.");

    // This will cancel all "scheduled" local notifications that haven't
    // been presented yet.
    [UIApplication.sharedApplication cancelAllLocalNotifications];
    // To clear all already presented local notifications, we need to
    // set the app badge number to zero after setting it to a non-zero value.
    [UIApplication sharedApplication].applicationIconBadgeNumber = 1;
    [UIApplication sharedApplication].applicationIconBadgeNumber = 0;
}

@end

NS_ASSUME_NONNULL_END

// MusicNotch's addition to mediaremote-adapter: streams every app that has a media
// session, not only the one macOS treats as "now playing". scripts/build.sh compiles it
// into MediaRemoteAdapter.framework, and Adapter/musicnotch-adapter.pl runs it through
// /usr/bin/perl, like the adapter's own commands.
//
// Each output line is
//   {"type":"sessions","elected":"<bundle id>"|null,"sessions":[{...}, ...]}
// where a session has the adapter's usual keys (title, artist, playing, durationMicros,
// elapsedTimeMicros, timestampEpochMicros, bundleIdentifier, ...) plus
// "artworkIdentifier" and "canSeek" (whether the app accepts a jump to a position).
// "artworkData" (base64) is only included when a session's artwork changes, so that lines
// stay small.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>

#import "MediaRemoteAdapter.h"
#import "adapter/globals.h"
#import "adapter/now_playing.h"
#import "utility/Debounce.h"
#import "utility/helpers.h"

typedef void (*GetClientsFn)(dispatch_queue_t, void (^)(NSArray *));
typedef void (*GetElectedClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*ClientBundleIDFn)(id);
typedef int (*ClientPIDFn)(id);
typedef id (*LocalOriginFn)(void);
typedef CFTypeRef (*PlayerPathCreateFn)(id, id, id);
typedef void (*InfoForPlayerFn)(id, void *, dispatch_queue_t, void (^)(NSDictionary *, NSError *));
// On macOS 27 the completion takes a single unsigned state; MRPlaybackStatePlaying is 1.
typedef void (*StateForPlayerFn)(id, dispatch_queue_t, void (^)(unsigned int));
// Note the order: the request comes before the player path.
typedef void (*RequestQueueForPlayerFn)(id, id, dispatch_queue_t, void (^)(id, NSError *));
typedef void (*SupportedCommandsForPlayerFn)(id, dispatch_queue_t, void (^)(NSArray *));
typedef int (*CommandInfoGetCommandFn)(id);
typedef Boolean (*CommandInfoGetEnabledFn)(id);

static GetClientsFn getClients;
static GetElectedClientFn getElectedClient;
static ClientBundleIDFn clientBundleID;
static ClientPIDFn clientPID;
static LocalOriginFn localOrigin;
static PlayerPathCreateFn playerPathCreate;
static InfoForPlayerFn infoForPlayer;
static StateForPlayerFn stateForPlayer;
static RequestQueueForPlayerFn requestQueueForPlayer;
static SupportedCommandsForPlayerFn supportedCommandsForPlayer;
static CommandInfoGetCommandFn commandInfoGetCommand;
static CommandInfoGetEnabledFn commandInfoGetEnabled;

static const unsigned int kPlaybackStatePlaying = 1;
static const int kSeekToPlaybackPositionCommand = 24;
static const double kArtworkPixels = 256;

// Only touched on the serial work queue.
static NSMutableDictionary<NSString *, NSString *> *sentArtwork;  // session key -> artwork id
static NSUInteger lastSessionCount;

static BOOL loadFunctions(void) {
    NSURL *url = [NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks/MediaRemote.framework"];
    CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)url);
    if (!bundle) return NO;
    getClients = CFBundleGetFunctionPointerForName(bundle, CFSTR("MRMediaRemoteGetNowPlayingClients"));
    getElectedClient = CFBundleGetFunctionPointerForName(bundle, CFSTR("MRMediaRemoteGetNowPlayingClient"));
    clientBundleID = CFBundleGetFunctionPointerForName(bundle, CFSTR("MRNowPlayingClientGetBundleIdentifier"));
    clientPID = CFBundleGetFunctionPointerForName(bundle, CFSTR("MRNowPlayingClientGetProcessIdentifier"));
    localOrigin = CFBundleGetFunctionPointerForName(bundle, CFSTR("MRMediaRemoteGetLocalOrigin"));
    playerPathCreate = CFBundleGetFunctionPointerForName(bundle, CFSTR("MRNowPlayingPlayerPathCreate"));
    infoForPlayer = CFBundleGetFunctionPointerForName(bundle, CFSTR("MRMediaRemoteGetNowPlayingInfoForPlayer"));
    stateForPlayer = CFBundleGetFunctionPointerForName(bundle, CFSTR("MRMediaRemoteGetPlaybackStateForPlayer"));
    requestQueueForPlayer = CFBundleGetFunctionPointerForName(
        bundle, CFSTR("MRMediaRemoteRequestNowPlayingPlaybackQueueForPlayer"));
    supportedCommandsForPlayer = CFBundleGetFunctionPointerForName(
        bundle, CFSTR("MRMediaRemoteGetSupportedCommandsForPlayer"));
    commandInfoGetCommand = CFBundleGetFunctionPointerForName(bundle, CFSTR("MRMediaRemoteCommandInfoGetCommand"));
    commandInfoGetEnabled = CFBundleGetFunctionPointerForName(bundle, CFSTR("MRMediaRemoteCommandInfoGetEnabled"));
    return getClients && getElectedClient && clientBundleID && clientPID && localOrigin &&
           playerPathCreate && infoForPlayer && stateForPlayer;
}

static dispatch_time_t replyDeadline(void) {
    return dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC);
}

/// Per-player now playing info has no artwork data, only an identifier. The image comes
/// from the player's playback queue, requested at a small size.
static NSData *requestArtwork(id playerPath, dispatch_queue_t replies) {
    Class requestClass = NSClassFromString(@"MRPlaybackQueueRequest");
    if (!requestQueueForPlayer || !requestClass) return nil;
    id request = ((id(*)(id, SEL))objc_msgSend)(
        requestClass, NSSelectorFromString(@"defaultPlaybackQueueRequest"));
    if (!request) return nil;
    ((void (*)(id, SEL, double))objc_msgSend)(request, NSSelectorFromString(@"setArtworkWidth:"), kArtworkPixels);
    ((void (*)(id, SEL, double))objc_msgSend)(request, NSSelectorFromString(@"setArtworkHeight:"), kArtworkPixels);

    __block NSData *data = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    requestQueueForPlayer(request, playerPath, replies, ^(id queue, NSError *error) {
      @try {
          id item = [[queue valueForKey:@"contentItems"] firstObject];
          id imageData = [[item valueForKey:@"artwork"] valueForKey:@"imageData"];
          if ([imageData isKindOfClass:[NSData class]]) data = imageData;
      } @catch (NSException *exception) {
      }
      dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, replyDeadline());
    return data;
}

/// Whether the player accepts a jump to a position (dragging MusicNotch's progress bar).
static BOOL canSeek(id playerPath, dispatch_queue_t replies) {
    if (!supportedCommandsForPlayer || !commandInfoGetCommand || !commandInfoGetEnabled) return NO;
    __block BOOL supported = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    supportedCommandsForPlayer(playerPath, replies, ^(NSArray *commands) {
      for (id info in commands) {
          if (commandInfoGetCommand(info) == kSeekToPlaybackPositionCommand && commandInfoGetEnabled(info)) {
              supported = YES;
          }
      }
      dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, replyDeadline());
    return supported;
}

static NSArray *readSessions(BOOL includeArtwork, NSString **electedBundleID) {
    dispatch_queue_t replies = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

    __block id elected = nil;
    dispatch_semaphore_t electedDone = dispatch_semaphore_create(0);
    getElectedClient(replies, ^(id client) {
      elected = client;
      dispatch_semaphore_signal(electedDone);
    });
    dispatch_semaphore_wait(electedDone, replyDeadline());
    *electedBundleID = elected ? (__bridge NSString *)clientBundleID(elected) : nil;

    __block NSArray *clients = nil;
    dispatch_semaphore_t clientsDone = dispatch_semaphore_create(0);
    getClients(replies, ^(NSArray *result) {
      clients = [result copy];
      dispatch_semaphore_signal(clientsDone);
    });
    dispatch_semaphore_wait(clientsDone, replyDeadline());

    NSMutableArray *sessions = [NSMutableArray array];
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    for (id client in clients) {
        NSString *bundleID = (__bridge NSString *)clientBundleID(client);
        if (bundleID.length == 0) continue;
        int pid = clientPID(client);
        NSString *key = [keys containsObject:bundleID] ? [NSString stringWithFormat:@"%@#%d", bundleID, pid] : bundleID;
        id path = (__bridge_transfer id)playerPathCreate(localOrigin(), client, nil);
        if (!path) continue;

        __block NSDictionary *info = nil;
        __block unsigned int state = 0;
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);
        infoForPlayer(path, NULL, replies, ^(NSDictionary *result, NSError *error) {
          info = [result copy];
          dispatch_group_leave(group);
        });
        dispatch_group_enter(group);
        stateForPlayer(path, replies, ^(unsigned int playbackState) {
          state = playbackState;
          dispatch_group_leave(group);
        });
        if (dispatch_group_wait(group, replyDeadline()) != 0) continue;
        if ([info[@"kMRMediaRemoteNowPlayingInfoTitle"] length] == 0) continue;

        NSMutableDictionary *session = convertNowPlayingInformation(info, true, false, true);
        session[@"sessionKey"] = key;
        session[kMRABundleIdentifier] = bundleID;
        if ([client respondsToSelector:NSSelectorFromString(@"parentApplicationBundleIdentifier")]) {
            NSString *parent = [client valueForKey:@"parentApplicationBundleIdentifier"];
            if (parent.length > 0) session[kMRAParentApplicationBundleIdentifier] = parent;
        }
        if (pid > 0) session[kMRAProcessIdentifier] = @(pid);
        // Metadata's playback rate can lag or be missing (Spotify); the player's state is reliable.
        session[kMRAPlaying] = @(state == kPlaybackStatePlaying);
        session[@"canSeek"] = @(canSeek(path, replies));

        NSString *artworkID = info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"];
        if (artworkID.length > 0) {
            session[@"artworkIdentifier"] = artworkID;
            if (includeArtwork && ![sentArtwork[key] isEqualToString:artworkID]) {
                NSData *data = requestArtwork(path, replies);
                if (data) {
                    session[kMRAArtworkData] = [data base64EncodedStringWithOptions:0];
                    sentArtwork[key] = artworkID;
                }
            }
        }
        [keys addObject:key];
        [sessions addObject:session];
    }
    // Forget artwork for sessions that ended, so it's sent again if they come back.
    for (NSString *key in sentArtwork.allKeys) {
        if (![keys containsObject:key]) [sentArtwork removeObjectForKey:key];
    }
    return sessions;
}

static void refreshAndPrint(BOOL includeArtwork) {
    NSString *elected = nil;
    NSArray *sessions = readSessions(includeArtwork, &elected);
    lastSessionCount = sessions.count;
    NSDictionary *message = @{
        @"type" : @"sessions",
        @"elected" : elected ?: (id)[NSNull null],
        @"sessions" : sessions,
    };
    NSString *line = serializeJsonDictionarySafe(message, false);
    if (line) printOutUnique(line);
}

void musicnotch_sessions(void) {
    if (!loadFunctions()) {
        printErr(@"Reading every media session isn't supported on this version of macOS");
        exit(1);
    }
    sentArtwork = [NSMutableDictionary dictionary];
    const BOOL includeArtwork = getenv("MUSICNOTCH_NO_ARTWORK") == NULL;
    const char *debounceEnv = getenv("MUSICNOTCH_DEBOUNCE_MS");
    const double debounceSeconds = MAX((debounceEnv ? atof(debounceEnv) : 150) / 1000.0, 0.05);

    dispatch_queue_t work = dispatch_queue_create("musicnotch.sessions", DISPATCH_QUEUE_SERIAL);
    Debounce *debounce = [[Debounce alloc] initWithDelay:debounceSeconds queue:work];

    // Apps in the background don't always announce their changes, so while more than one
    // app has a session, also check every 2 seconds. With one or none, nothing runs.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, work);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    __block BOOL timerRunning = NO;
    __block void (^refresh)(void) = nil;
    refresh = ^{
      refreshAndPrint(includeArtwork);
      BOOL wantTimer = lastSessionCount > 1;
      if (wantTimer && !timerRunning) {
          dispatch_resume(timer);
          timerRunning = YES;
      } else if (!wantTimer && timerRunning) {
          dispatch_suspend(timer);
          timerRunning = NO;
      }
    };
    dispatch_source_set_event_handler(timer, ^{ refresh(); });

    // MediaRemote posts its changes as local notifications in this process.
    id mediaObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:nil
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *notification) {
                  if ([notification.name hasPrefix:@"kMR"]) [debounce call:refresh];
                }];
    id terminationObserver = [NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:NSWorkspaceDidTerminateApplicationNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *notification) {
                  [debounce call:refresh];
                }];

    dispatch_async(work, refresh);
    g_mediaRemote.registerForNowPlayingNotifications(work);
    CFRunLoopRun();

    g_mediaRemote.unregisterForNowPlayingNotifications();
    [NSNotificationCenter.defaultCenter removeObserver:mediaObserver];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:terminationObserver];
}

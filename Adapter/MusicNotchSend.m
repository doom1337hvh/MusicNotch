// MusicNotch's addition to mediaremote-adapter: sends a media command to a specific app.
//
// MediaRemote delivers every command to the app macOS currently treats as "now playing",
// whichever player the command names, and macOS keeps that app even after it pauses. So
// to reach another app, this briefly overrides the "now playing" app: enable the override,
// point it at the target, wait until macOS has actually picked it, send the command, and
// clear the override again, all in well under a second.
//
// The override is stored system-wide and outlives this process, so it's cleared on every
// way out (normal exit, failure, termination signals). While it's on, a marker file
// records it; if this process is ever killed outright, the next run of
// `musicnotch_clear_override` (MusicNotch does this on launch and before each command)
// switches it off.

#include <signal.h>
#include <unistd.h>

#import <Foundation/Foundation.h>

#import "adapter/globals.h"
#import "utility/helpers.h"

typedef void (*SetOverrideEnabledFn)(Boolean);
typedef void (*SetOverrideAppFn)(CFStringRef);
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);
typedef CFStringRef (*ClientBundleIDFn)(id);

static SetOverrideEnabledFn setOverrideEnabled;
static SetOverrideAppFn setOverrideApp;
static SendCommandFn sendCommand;
static ClientBundleIDFn clientBundleID;

static volatile sig_atomic_t overrideActive = 0;
static char markerPath[PATH_MAX];

static BOOL loadFunctions(void) {
    NSURL *url = [NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks/MediaRemote.framework"];
    CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)url);
    if (!bundle) return NO;
    setOverrideEnabled = CFBundleGetFunctionPointerForName(
        bundle, CFSTR("MRMediaRemoteSetNowPlayingApplicationOverrideEnabled"));
    setOverrideApp = CFBundleGetFunctionPointerForName(
        bundle, CFSTR("MRMediaRemoteSetOverriddenNowPlayingApplication"));
    sendCommand = CFBundleGetFunctionPointerForName(bundle, CFSTR("MRMediaRemoteSendCommand"));
    clientBundleID = CFBundleGetFunctionPointerForName(bundle, CFSTR("MRNowPlayingClientGetBundleIdentifier"));
    return setOverrideEnabled && setOverrideApp && sendCommand && clientBundleID;
}

/// The marker file's path comes from MusicNotch, so it lives in the app's caches folder.
static void loadMarkerPath(void) {
    const char *path = getenv("MUSICNOTCH_OVERRIDE_MARKER");
    strlcpy(markerPath, path ? path : "", sizeof(markerPath));
}

/// Asks the daemon which app is "now playing". Also serves as a round trip, so requests
/// sent before it have been delivered.
static BOOL electedAppMatches(NSString *bundleID) {
    __block BOOL matches = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    g_mediaRemote.getNowPlayingClient(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(id client) {
      if (client && bundleID) {
          NSString *clientID = (__bridge NSString *)clientBundleID(client);
          NSString *parent = [client respondsToSelector:NSSelectorFromString(@"parentApplicationBundleIdentifier")]
                                 ? [client valueForKey:@"parentApplicationBundleIdentifier"]
                                 : nil;
          matches = [clientID isEqualToString:bundleID] || [parent isEqualToString:bundleID];
      }
      dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    return matches;
}

static void clearOverride(void) {
    if (!overrideActive) return;
    overrideActive = 0;
    // Both setters skip a value equal to the one this process last set; this process set
    // both, so these calls do reach the daemon.
    setOverrideApp(NULL);
    setOverrideEnabled(false);
    electedAppMatches(nil);
    if (markerPath[0]) unlink(markerPath);
}

// Not async-signal-safe, but an override left on would send everyone's media commands
// (media keys, Control Center) to the wrong app, which is worse.
static void handleSignal(int sig) {
    clearOverride();
    signal(sig, SIG_DFL);
    raise(sig);
}

/// Points the override at `bundleID` and waits up to 600 ms for the daemon to pick it.
static BOOL elect(NSString *bundleID) {
    if (bundleID.length == 0) return NO;
    setOverrideApp((__bridge CFStringRef)bundleID);
    for (int waited = 0; waited <= 600; waited += 50) {
        if (electedAppMatches(bundleID)) return YES;
        usleep(50 * 1000);
    }
    return NO;
}

/// MUSICNOTCH_COMMAND: the MRCommand number (0 play, 1 pause, 2 toggle, 4 next, 5 previous),
/// or MUSICNOTCH_SEEK: the position to jump to, in seconds.
/// MUSICNOTCH_TARGET: the session's bundle ID; MUSICNOTCH_TARGET_PARENT: its parent app's, if any.
void musicnotch_send(void) {
    if (!loadFunctions()) {
        printErr(@"Sending to a specific app isn't supported on this version of macOS");
        exit(1);
    }
    loadMarkerPath();
    const char *commandEnv = getenv("MUSICNOTCH_COMMAND");
    const char *seekEnv = getenv("MUSICNOTCH_SEEK");
    const char *targetEnv = getenv("MUSICNOTCH_TARGET");
    const char *parentEnv = getenv("MUSICNOTCH_TARGET_PARENT");
    if ((!commandEnv && !seekEnv) || !targetEnv || (seekEnv && !g_mediaRemote.setElapsedTime)) {
        printErr(@"Missing command or target");
        exit(1);
    }
    NSString *target = @(targetEnv);
    NSString *parent = parentEnv ? @(parentEnv) : nil;

    // Record the override before turning it on, so a crash in between is recoverable.
    if (markerPath[0]) {
        NSString *pid = [NSString stringWithFormat:@"%d", getpid()];
        [pid writeToFile:@(markerPath) atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    atexit(clearOverride);
    signal(SIGINT, handleSignal);
    signal(SIGTERM, handleSignal);
    signal(SIGHUP, handleSignal);

    // Enabled first: setting the app while the override is off leaves the daemon with no
    // "now playing" app until it's enabled.
    overrideActive = 1;
    setOverrideEnabled(true);
    if (!elect(target) && !elect(parent)) {
        // Never picked, so don't send anything: it would reach a different app.
        clearOverride();
        printErr([NSString stringWithFormat:@"%@ isn't registered with MediaRemote", target]);
        exit(2);
    }
    if (seekEnv) {
        g_mediaRemote.setElapsedTime(MAX(atof(seekEnv), 0));
    } else {
        sendCommand(atoi(commandEnv), NULL);
    }
    // The daemon resolves where a command goes when it handles it, which can be after
    // sendCommand returned; clearing the override sooner would send it elsewhere.
    usleep(250 * 1000);
    clearOverride();
}

/// Switches off an override a killed `musicnotch_send` left behind.
void musicnotch_clear_override(void) {
    if (!loadFunctions()) exit(1);
    loadMarkerPath();
    // A fresh process hasn't set anything yet, and setting "off" when it last set "off"
    // is skipped; so set "on" first for the "off" to reach the daemon.
    setOverrideEnabled(true);
    setOverrideEnabled(false);
    electedAppMatches(nil);
    if (markerPath[0]) unlink(markerPath);
}

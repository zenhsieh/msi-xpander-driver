#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>

static BOOL MenuInspectionMode;

static NSString *InterfaceLanguage(void) {
    NSString *choice=[NSUserDefaults.standardUserDefaults stringForKey:@"MSIInterfaceLanguage"];
    if ([choice isEqual:@"en"] || [choice isEqual:@"zh-Hant"]) return choice;
    NSString *preferred=[NSBundle preferredLocalizationsFromArray:@[@"en",@"zh-Hant"]
                                                 forPreferences:NSLocale.preferredLanguages].firstObject;
    return [preferred isEqual:@"zh-Hant"] ? @"zh-Hant" : @"en";
}
static NSString *L(NSString *key) {
    NSString *path=[NSBundle.mainBundle pathForResource:InterfaceLanguage() ofType:@"lproj"];
    NSBundle *bundle=path?[NSBundle bundleWithPath:path]:NSBundle.mainBundle;
    return [bundle localizedStringForKey:key value:key table:nil];
}

@interface XpanderMenuController : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenu *rootMenu;
@property(nonatomic, strong) NSMenuItem *statusHeader;
@property(nonatomic, strong) NSMenuItem *errorHeader;
@property(nonatomic, strong) NSMenuItem *loginItem;
@property(nonatomic, strong) NSMenuItem *testWindowItem;
@property(nonatomic, strong) NSMenuItem *logsItem;
@property(nonatomic, strong) NSMenuItem *quitItem;
@property(nonatomic, strong) NSMutableArray<NSMenuItem *> *controlItems;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMenuItem *> *modeItems;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMenuItem *> *fpsItems;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMenuItem *> *desktopQualityItems;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMenuItem *> *kioskQualityItems;
@property(nonatomic, strong) NSDictionary *state;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic, strong) dispatch_queue_t commands;
@property(nonatomic, copy) NSString *currentAction;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL statusPending;
@property(nonatomic) BOOL menuTracking;
@property(nonatomic) NSUInteger commandGeneration;
@property(nonatomic) BOOL terminationPending;
@property(nonatomic) BOOL readyToQuit;
@property(nonatomic) BOOL macScreensaverRunning;
@property(nonatomic) BOOL macScreensSleeping;
@property(nonatomic) BOOL macSystemSleeping;
@property(nonatomic, copy) NSString *pendingSystemState;
@property(nonatomic, strong) NSTimer *systemStateTimer;
@end

@implementation XpanderMenuController

- (NSString *)stringForKey:(NSString *)key {
    id value=self.state[key];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

- (double)numberForKey:(NSString *)key {
    id value=self.state[key];
    return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : NAN;
}

- (NSString *)modeTitle {
    NSString *mode=[self stringForKey:@"mode"];
    if ([mode isEqualToString:@"kiosk"]) return @"Kiosk";
    if ([mode isEqualToString:@"desktop"]) return L(@"Extended Desktop");
    if ([mode isEqualToString:@"screensaver"]) return L(@"Screen Saver");
    if ([mode isEqualToString:@"stopped"]) return L(@"Screen Off");
    return L(@"Reading status…");
}

- (NSString *)operationTitle {
    if (self.terminationPending) return L(@"Stopping output and quitting…");
    if ([self.currentAction isEqualToString:@"resume"]) return L(@"Restoring the selected mode…");
    if ([self.currentAction isEqualToString:@"kiosk"]) return L(@"Starting Kiosk…");
    if ([self.currentAction isEqualToString:@"desktop"]) return L(@"Starting extended desktop…");
    if ([self.currentAction isEqualToString:@"screensaver"]) return L(@"Starting screen saver…");
    if ([self.currentAction isEqualToString:@"stop"]) return L(@"Stopping output…");
    if ([self.currentAction isEqualToString:@"restart"]) return L(@"Restarting output…");
    if ([self.currentAction isEqualToString:@"system-state"]) return L(@"Following Mac display state…");
    return L(@"Applying settings…");
}

- (NSMenuItem *)actionItem:(NSString *)title action:(NSString *)action value:(NSString *)value {
    NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:title action:@selector(chooseAction:) keyEquivalent:@""];
    item.target=self;
    item.representedObject=value ? @{@"action":action,@"value":value} : @{@"action":action};
    [self.controlItems addObject:item];
    return item;
}

- (NSMenuItem *)settingsMenu:(NSString *)title action:(NSString *)action values:(NSArray<NSString *> *)values
                     items:(NSMutableDictionary<NSString *, NSMenuItem *> *)items suffix:(NSString *)suffix {
    NSMenuItem *parent=[[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *submenu=[[NSMenu alloc] initWithTitle:title];
    submenu.autoenablesItems=NO;
    for (NSString *value in values) {
        NSString *itemTitle=[value stringByAppendingString:suffix];
        if ([action isEqualToString:@"set-desktop-fps"]) itemTitle=[NSString stringWithFormat:L(@"%@ updates per second"),value];
        NSMenuItem *item=[self actionItem:itemTitle action:action value:value];
        items[value]=item;
        [submenu addItem:item];
    }
    parent.submenu=submenu;
    [self.controlItems addObject:parent];
    return parent;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    dispatch_queue_attr_t attributes=dispatch_queue_attr_make_with_autorelease_frequency(
        DISPATCH_QUEUE_SERIAL,DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
    self.commands=dispatch_queue_create("com.digiter.xpander.menu.commands",attributes);
    self.state=@{};
    [self buildMenu];
    [self observeMacDisplayState];
    [self flushSystemState];
    self.pollTimer=[NSTimer timerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [self requestStatus];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}

- (void)buildMenu {
    self.controlItems=[NSMutableArray array];
    self.modeItems=[NSMutableDictionary dictionary];
    self.fpsItems=[NSMutableDictionary dictionary];
    self.desktopQualityItems=[NSMutableDictionary dictionary];
    self.kioskQualityItems=[NSMutableDictionary dictionary];
    if (!MenuInspectionMode && !self.statusItem) self.statusItem=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *button=self.statusItem.button;
    NSImage *icon=[NSImage imageWithSystemSymbolName:@"display" accessibilityDescription:@"MSI Xpander"];
    if (!icon) icon=[NSImage imageNamed:NSImageNameComputer];
    icon.template=YES;
    button.image=icon;
    button.imagePosition=NSImageOnly;
    button.accessibilityLabel=@"MSI Xpander";
    button.accessibilityIdentifier=@"msi-xpander-menu";

    NSMenu *menu=[[NSMenu alloc] initWithTitle:@"MSI Xpander"];
    menu.autoenablesItems=NO;
    menu.delegate=self;
    self.statusHeader=[[NSMenuItem alloc] initWithTitle:L(@"Reading status…") action:nil keyEquivalent:@""];
    self.statusHeader.enabled=NO;
    [menu addItem:self.statusHeader];
    self.errorHeader=[[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    self.errorHeader.enabled=NO;
    self.errorHeader.hidden=YES;
    [menu addItem:self.errorHeader];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *displayParent=[[NSMenuItem alloc] initWithTitle:L(@"Display") action:nil keyEquivalent:@""];
    NSMenu *displayMenu=[[NSMenu alloc] initWithTitle:L(@"Display")];
    displayMenu.autoenablesItems=NO;
    NSArray *modes=@[@[@"kiosk",@"Kiosk"],@[@"desktop",L(@"Extended Desktop")],@[@"screensaver",L(@"Screen Saver")],@[@"stop",L(@"Screen Off")]];
    for (NSArray<NSString *> *mode in modes) {
        NSMenuItem *item=[self actionItem:mode[1] action:mode[0] value:nil];
        // Use AppKit's standard selection checkmark.
        self.modeItems[[mode[0] isEqualToString:@"stop"] ? @"stopped" : mode[0]]=item;
        if ([mode[0] isEqualToString:@"stop"]) item.toolTip=L(@"Show black and stop updating. The panel remains powered by USB.");
        [displayMenu addItem:item];
    }
    displayParent.submenu=displayMenu;
    [self.controlItems addObject:displayParent];
    [menu addItem:displayParent];
    NSMenuItem *settingsParent=[[NSMenuItem alloc] initWithTitle:L(@"Settings") action:nil keyEquivalent:@""];
    NSMenu *settings=[[NSMenu alloc] initWithTitle:L(@"Settings")];settings.autoenablesItems=NO;
    settingsParent.submenu=settings;[menu addItem:settingsParent];[self.controlItems addObject:settingsParent];
    NSMenuItem *toolsParent=[[NSMenuItem alloc] initWithTitle:L(@"Tools") action:nil keyEquivalent:@""];
    NSMenu *tools=[[NSMenu alloc] initWithTitle:L(@"Tools")];tools.autoenablesItems=NO;
    toolsParent.submenu=tools;[menu addItem:toolsParent];[self.controlItems addObject:toolsParent];
    [settings addItem:[self settingsMenu:L(@"Desktop Update Rate") action:@"set-desktop-fps" values:@[@"30",@"60"] items:self.fpsItems suffix:@""]];
    [settings addItem:[self settingsMenu:L(@"Desktop Quality") action:@"set-desktop-quality" values:@[@"0.75",@"0.9",@"1.0"] items:self.desktopQualityItems suffix:@""]];
    [settings addItem:[self settingsMenu:L(@"Kiosk Quality") action:@"set-kiosk-quality" values:@[@"0.75",@"0.9",@"1.0"] items:self.kioskQualityItems suffix:@""]];
    NSMenuItem *sourceItem=[[NSMenuItem alloc] initWithTitle:L(@"Configure Kiosk Source…") action:@selector(configureKioskSource:) keyEquivalent:@""];
    sourceItem.target=self;
    [self.controlItems addObject:sourceItem];
    [settings addItem:sourceItem];
    NSMenuItem *widgetsHelp=[[NSMenuItem alloc] initWithTitle:L(@"Use Widgets on the Desktop…") action:@selector(showWidgetsHelp:) keyEquivalent:@""];
    widgetsHelp.target=self;
    [self.controlItems addObject:widgetsHelp];[tools addItem:widgetsHelp];
    NSMenuItem *testOptions=[[NSMenuItem alloc] initWithTitle:L(@"Testing") action:nil keyEquivalent:@""];
    NSMenu *testMenu=[[NSMenu alloc] initWithTitle:L(@"Testing")];
    testMenu.autoenablesItems=NO;
    self.testWindowItem=[self actionItem:L(@"Show Test Window") action:@"set-test-window" value:nil];
    [testMenu addItem:self.testWindowItem];
    testOptions.submenu=testMenu;
    [self.controlItems addObject:testOptions];
    [tools addItem:testOptions];
    [tools addItem:[self actionItem:L(@"Restart Output") action:@"restart" value:nil]];
    [tools addItem:NSMenuItem.separatorItem];
    NSMenuItem *permissionItem=[[NSMenuItem alloc] initWithTitle:L(@"Screen Recording Permission…") action:@selector(requestScreenRecordingPermission:) keyEquivalent:@""];
    permissionItem.target=self;
    [self.controlItems addObject:permissionItem];
    [tools addItem:permissionItem];
    self.logsItem=[[NSMenuItem alloc] initWithTitle:L(@"Open Logs") action:@selector(openLogs:) keyEquivalent:@""];
    self.logsItem.target=self;
    [tools addItem:self.logsItem];
    self.loginItem=[self actionItem:L(@"Open at Login") action:@"set-login" value:nil];
    [settings addItem:self.loginItem];
    NSMenuItem *languageParent=[[NSMenuItem alloc] initWithTitle:L(@"Language") action:nil keyEquivalent:@""];
    NSMenu *languages=[[NSMenu alloc] initWithTitle:L(@"Language")];languages.autoenablesItems=NO;
    NSString *choice=[NSUserDefaults.standardUserDefaults stringForKey:@"MSIInterfaceLanguage"] ?: @"system";
    for (NSArray<NSString *> *row in @[@[@"system",L(@"Follow System")],@[@"zh-Hant",L(@"Traditional Chinese")],@[@"en",L(@"English")]]) {
        NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:row[1] action:@selector(chooseLanguage:) keyEquivalent:@""];
        item.target=self;item.representedObject=row[0];item.state=[choice isEqual:row[0]]?NSControlStateValueOn:NSControlStateValueOff;
        [languages addItem:item];[self.controlItems addObject:item];
    }
    languageParent.submenu=languages;[settings addItem:languageParent];[self.controlItems addObject:languageParent];
    [menu addItem:NSMenuItem.separatorItem];
    self.quitItem=[[NSMenuItem alloc] initWithTitle:L(@"Quit and Stop Output") action:@selector(quitAndStop:) keyEquivalent:@"q"];
    self.quitItem.target=self;
    [menu addItem:self.quitItem];
    self.rootMenu=menu;
    self.statusItem.menu=menu;
    [self refreshMenu];
}

- (void)chooseLanguage:(NSMenuItem *)sender {
    if (self.busy || self.terminationPending) return;
    NSString *choice=sender.representedObject;
    if (![@[@"system",@"en",@"zh-Hant"] containsObject:choice]) return;
    [NSUserDefaults.standardUserDefaults setObject:choice forKey:@"MSIInterfaceLanguage"];
    self.commandGeneration++;
    NSMutableDictionary *state=[self.state mutableCopy];[state removeObjectForKey:@"last_error"];self.state=state;
    [self buildMenu];
    if ([[self stringForKey:@"mode"] isEqual:@"screensaver"]) [self runAction:@"restart" value:nil terminating:NO];
    else [self requestStatus];
}

- (void)refreshMenu {
    BOOL transition=self.terminationPending || self.busy;
    NSString *title=transition ? [self operationTitle] : [NSString stringWithFormat:L(@"Current mode: %@"),[self modeTitle]];
    if (!transition && [self.state[@"following_mac"] boolValue]) title=[title stringByAppendingString:L(@" (Following Mac)")];
    self.statusHeader.title=title;
    self.statusItem.button.toolTip=[NSString stringWithFormat:@"MSI Xpander — %@",title];
    BOOL enabled=!self.busy && !self.terminationPending;
    for (NSMenuItem *item in self.controlItems) item.enabled=enabled;
    self.quitItem.enabled=enabled;
    NSString *mode=[self stringForKey:@"mode"];
    [self.modeItems enumerateKeysAndObjectsUsingBlock:^(NSString *key,NSMenuItem *item,BOOL *stop) {
        (void)stop;
        item.state=[key isEqualToString:mode] ? NSControlStateValueOn : NSControlStateValueOff;
    }];
    [self updateChecks:self.fpsItems value:[self numberForKey:@"desktop_fps"]];
    [self updateChecks:self.desktopQualityItems value:[self numberForKey:@"desktop_quality"]];
    [self updateChecks:self.kioskQualityItems value:[self numberForKey:@"kiosk_quality"]];
    id login=self.state[@"launch_at_login"];
    self.loginItem.state=[login isKindOfClass:NSNumber.class] && [login boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    id testWindow=self.state[@"test_window"];
    self.testWindowItem.state=[testWindow isKindOfClass:NSNumber.class] && [testWindow boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    self.logsItem.enabled=[self stringForKey:@"logs_path"].length>0;
    NSString *error=[self stringForKey:@"last_error"];
    self.errorHeader.hidden=error.length==0;
    self.errorHeader.title=error.length>80 ? [[error substringToIndex:80] stringByAppendingString:@"…"] : error;
}

- (void)updateChecks:(NSDictionary<NSString *, NSMenuItem *> *)items value:(double)value {
    [items enumerateKeysAndObjectsUsingBlock:^(NSString *key,NSMenuItem *item,BOOL *stop) {
        (void)stop;
        item.state=isfinite(value) && fabs(key.doubleValue-value)<0.0001 ? NSControlStateValueOn : NSControlStateValueOff;
    }];
}

- (void)chooseAction:(NSMenuItem *)sender {
    if (self.busy || self.terminationPending) return;
    NSDictionary *command=sender.representedObject;
    NSString *action=command[@"action"];
    NSString *value=command[@"value"];
    if ([action isEqualToString:@"set-login"]) value=self.loginItem.state==NSControlStateValueOn ? @"0" : @"1";
    if ([action isEqualToString:@"set-test-window"]) value=self.testWindowItem.state==NSControlStateValueOn ? @"0" : @"1";
    [self runAction:action value:value terminating:NO];
}

- (void)showError:(NSString *)message {
    NSAlert *alert=[NSAlert new];
    alert.alertStyle=NSAlertStyleWarning;
    alert.messageText=L(@"Unable to Complete Action");
    alert.informativeText=message.length ? message : L(@"Try again later, or open the logs for details.");
    [alert addButtonWithTitle:L(@"OK")];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)requestScreenRecordingPermission:(id)sender {
    (void)sender;
    // This method is only reached through an explicit permission menu action
    // or the user's permission-help button, never through a Kiosk/status poll.
    [NSApp activateIgnoringOtherApps:YES];
    CGRequestScreenCaptureAccess();
    NSURL *settings=[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"];
    if (![NSWorkspace.sharedWorkspace openURL:settings])
        [self showError:L(@"Open System Settings → Privacy & Security → Screen & System Audio Recording and allow MSI Xpander.")];
}

- (void)showControllerError:(NSString *)message action:(NSString *)action {
    BOOL desktopRequest=[action isEqualToString:@"desktop"] || [action isEqualToString:@"resume"];
    BOOL permissionError=message.length && ([message rangeOfString:L(@"Screen Recording") options:NSCaseInsensitiveSearch].location!=NSNotFound || [message rangeOfString:@"螢幕錄製"].location!=NSNotFound);
    if (!desktopRequest || !permissionError) {
        [self showError:message];
        return;
    }
    NSAlert *alert=[NSAlert new];
    alert.alertStyle=NSAlertStyleWarning;
    alert.messageText=L(@"MSI Xpander Needs Screen Recording Permission");
    alert.informativeText=[NSString stringWithFormat:L(@"Allow MSI Xpander in System Settings → Privacy & Security → Screen & System Audio Recording. If an old enabled entry still fails, remove it, click + to add the current MSI Xpander.app, and allow it. Then quit and reopen MSI Xpander.\n\nCurrent app: %@"),NSBundle.mainBundle.bundlePath.stringByAbbreviatingWithTildeInPath];
    [alert addButtonWithTitle:L(@"Open Settings")];
    [alert addButtonWithTitle:L(@"Later")];
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal]==NSAlertFirstButtonReturn) [self requestScreenRecordingPermission:nil];
}

- (void)configureKioskSource:(id)sender {
    (void)sender;
    if (self.busy || self.terminationPending) return;
    NSAlert *alert=[NSAlert new];
    alert.messageText=L(@"Configure Kiosk Source");
    alert.informativeText=L(@"Enter a command that writes a 1920×720 PNG. After saving, choose Kiosk to start output.");
    [alert addButtonWithTitle:L(@"Save")];
    [alert addButtonWithTitle:L(@"Cancel")];
    NSTextField *input=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,480,26)];
    input.stringValue=[self stringForKey:@"source_cmd"];
    input.placeholderString=L(@"Example: ssh my-host ~/bin/render-dashboard");
    input.font=[NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    input.accessibilityLabel=L(@"Kiosk source command");
    alert.accessoryView=input;
    [NSApp activateIgnoringOtherApps:YES];
    for (;;) {
        alert.window.initialFirstResponder=input;
        [alert.window makeFirstResponder:input];
        [input selectText:nil];
        if ([alert runModal]!=NSAlertFirstButtonReturn) return;
        NSString *command=[input.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!command.length) {
            [self showError:L(@"Enter a Kiosk frame source command.")];
            continue;
        }
        [self runAction:@"set-frame-cmd" value:command terminating:NO];
        return;
    }
}

- (void)showWidgetsHelp:(id)sender {
    (void)sender;
    NSAlert *alert=[NSAlert new];
    alert.messageText=L(@"Use macOS Desktop Widgets");
    alert.informativeText=L(@"Choose Display → Extended Desktop, then move the pointer to Xpander. Right-click the desktop and choose Edit Widgets to add a clock, calendar, and other widgets. You can also place apps there and decide how to use the desktop. macOS manages widgets and their positions.");
    [alert addButtonWithTitle:L(@"Got It")];
    [NSApp activateIgnoringOtherApps:YES];[alert runModal];
}

- (BOOL)physicalScreensAsleep {
    CGDirectDisplayID displays[32];uint32_t count=0,physical=0,asleep=0;
    if (CGGetOnlineDisplayList(32,displays,&count)!=kCGErrorSuccess) return NO;
    for (uint32_t i=0;i<count;i++) {
        // Both app-owned virtual identities are excluded from physical power state.
        if (CGDisplayVendorNumber(displays[i])==3504 &&
            (CGDisplayModelNumber(displays[i])==31008 || CGDisplayModelNumber(displays[i])==31009)) continue;
        physical++;if(CGDisplayIsAsleep(displays[i])) asleep++;
    }
    return physical>0 && asleep==physical;
}

- (void)queueSystemState {
    NSDictionary *snapshot=@{@"screensaver":@(self.macScreensaverRunning),
        @"screen_sleep":@(self.macScreensSleeping),@"system_sleep":@(self.macSystemSleeping)};
    NSData *data=[NSJSONSerialization dataWithJSONObject:snapshot options:0 error:NULL];
    self.pendingSystemState=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [self.systemStateTimer invalidate];
    self.systemStateTimer=[NSTimer timerWithTimeInterval:.15 repeats:NO block:^(NSTimer *timer){
        (void)timer;[self flushSystemState];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.systemStateTimer forMode:NSRunLoopCommonModes];
}

- (void)flushSystemState {
    if (self.busy || self.terminationPending || !self.pendingSystemState) return;
    NSString *snapshot=self.pendingSystemState;self.pendingSystemState=nil;
    [self runAction:@"system-state" value:snapshot terminating:NO];
}

- (void)macDisplayStateChanged:(NSNotification *)note {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{[self macDisplayStateChanged:note];});return;
    }
    NSString *name=note.name;
    // A Settings preview is not the system's actual idle screensaver.
    if ([note.object isKindOfClass:NSString.class] && [note.object isEqual:@"runFromPref"]) return;
    if ([name isEqual:@"com.apple.screensaver.didstart"]) self.macScreensaverRunning=YES;
    else if ([name isEqual:@"com.apple.screensaver.didstop"]) self.macScreensaverRunning=NO;
    else if ([name isEqual:NSWorkspaceScreensDidSleepNotification]) self.macScreensSleeping=YES;
    else if ([name isEqual:NSWorkspaceScreensDidWakeNotification]) self.macScreensSleeping=NO;
    else if ([name isEqual:NSWorkspaceWillSleepNotification]) self.macSystemSleeping=YES;
    else if ([name isEqual:NSWorkspaceDidWakeNotification]) self.macSystemSleeping=NO;
    [self queueSystemState];
    if ([name isEqual:NSWorkspaceScreensDidWakeNotification] || [name isEqual:NSWorkspaceDidWakeNotification]) {
        // Coalesce another sample after WindowServer/USB have had time to settle.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            if (!self.terminationPending) [self queueSystemState];
        });
    }
}

- (void)observeMacDisplayState {
    NSNotificationCenter *workspace=NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSNotificationName name in @[NSWorkspaceScreensDidSleepNotification,NSWorkspaceScreensDidWakeNotification,
                                      NSWorkspaceWillSleepNotification,NSWorkspaceDidWakeNotification])
        [workspace addObserver:self selector:@selector(macDisplayStateChanged:) name:name object:nil];
    for (NSString *name in @[@"com.apple.screensaver.didstart",@"com.apple.screensaver.didstop"])
        [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(macDisplayStateChanged:)
             name:name object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    self.macScreensSleeping=[self physicalScreensAsleep];
    [self queueSystemState];
}

- (void)executeControllerAction:(NSString *)action value:(NSString *)value
                    completion:(void (^)(NSDictionary *,NSString *,BOOL))completion {
    dispatch_async(self.commands, ^{
        NSDictionary *response=nil;
        NSString *error=nil;
        BOOL ok=NO;
        NSURL *standalone=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"controller/XpanderController"];
        NSURL *script=[NSBundle.mainBundle URLForResource:@"controller" withExtension:@"py"];
        NSURL *executable=nil;
        NSArray *arguments=value ? @[action,value] : @[action];
        if (standalone && [NSFileManager.defaultManager fileExistsAtPath:standalone.path]) {
            if ([NSFileManager.defaultManager isExecutableFileAtPath:standalone.path]) executable=standalone;
        } else if (script) {
            // Development bundles may carry the source controller. Installed
            // distribution bundles use the frozen executable and need no Python.
            executable=[NSURL fileURLWithPath:@"/usr/bin/python3"];
            arguments=[@[script.path] arrayByAddingObjectsFromArray:arguments];
        }
        if (!executable) {
            error=L(@"Unable to start the panel controller. Reopen MSI Xpander.");
        } else {
            NSTask *task=[NSTask new];
            task.executableURL=executable;
            task.arguments=arguments;
            NSMutableDictionary *environment=[NSProcessInfo.processInfo.environment mutableCopy];
            environment[@"MSI_UI_LANGUAGE"]=InterfaceLanguage();task.environment=environment;
            NSPipe *output=[NSPipe pipe];
            task.standardOutput=output;
            task.standardError=NSFileHandle.fileHandleWithNullDevice;
            NSError *launchError=nil;
            if (![task launchAndReturnError:&launchError]) {
                error=L(@"Unable to start the panel controller. Try again later.");
            } else {
                NSData *data=[output.fileHandleForReading readDataToEndOfFile];
                [task waitUntilExit];
                id parsed=data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
                if ([parsed isKindOfClass:NSDictionary.class]) response=parsed;
                id success=response[@"ok"];
                ok=task.terminationStatus==0 && [success isKindOfClass:NSNumber.class] && [success boolValue];
                if (!ok) {
                    id detail=response[@"last_error"];
                    if (![detail isKindOfClass:NSString.class] || ![detail length]) detail=response[@"error"];
                    error=[detail isKindOfClass:NSString.class] && [detail length] ? detail : L(@"Unable to read panel status. Try again later.");
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(response,error,ok);
        });
    });
}

- (BOOL)updateState:(NSDictionary *)response error:(NSString *)error {
    NSMutableDictionary *updated=[self.state mutableCopy] ?: [NSMutableDictionary dictionary];
    // Ignore backend fields that have no visual representation (for example a
    // timestamp or process counter) so they cannot cause periodic menu redraws.
    for (NSString *key in @[@"mode",@"desktop_fps",@"desktop_quality",@"kiosk_quality",
                            @"launch_at_login",@"test_window",@"last_error",@"logs_path",@"source_cmd",@"selected_mode",@"following_mac",@"system_state"]) {
        id value=response[key];
        if (value==NSNull.null) [updated removeObjectForKey:key];
        else if (value) updated[key]=value;
    }
    if (error) updated[@"last_error"]=error;
    if ([self.state isEqualToDictionary:updated]) return NO;
    self.state=updated;
    return YES;
}

- (void)requestStatus {
    if (self.statusPending || self.busy || self.terminationPending || self.menuTracking) return;
    self.statusPending=YES;
    NSUInteger generation=self.commandGeneration;
    [self executeControllerAction:@"status" value:nil completion:^(NSDictionary *response,NSString *error,BOOL ok) {
        (void)ok;
        self.statusPending=NO;
        // A click is allowed while a passive query runs. Its command is queued
        // serially and invalidates this older reply, even if it already finished.
        if (self.busy || self.terminationPending || self.menuTracking || generation!=self.commandGeneration) return;
        if ([self updateState:response error:error]) [self refreshMenu];
    }];
}

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    self.menuTracking=YES;
}

- (void)menuDidClose:(NSMenu *)menu {
    (void)menu;
    self.menuTracking=NO;
}

- (void)runAction:(NSString *)action value:(NSString *)value terminating:(BOOL)terminating {
    if ([action isEqualToString:@"status"]) { [self requestStatus]; return; }
    if (self.busy) return;
    self.busy=YES;
    self.currentAction=action;
    self.commandGeneration++;
    [self refreshMenu];
    [self executeControllerAction:action value:value completion:^(NSDictionary *response,NSString *error,BOOL ok) {
        [self updateState:response error:error];
        self.busy=NO;
        self.currentAction=nil;
        // Mutating operations must re-enable controls even when the returned
        // settings are identical; passive status queries never toggle them.
        [self refreshMenu];
        if (terminating) {
            if (ok) {
                self.readyToQuit=YES;
                [NSApp replyToApplicationShouldTerminate:YES];
            } else {
                self.terminationPending=NO;
                [NSApp replyToApplicationShouldTerminate:NO];
                [self refreshMenu];
                [self showError:error];
            }
        } else {
            if (!ok && ![action isEqualToString:@"system-state"]) [self showControllerError:error action:action];
            if (self.terminationPending) [self beginTerminationIfIdle];
            else [self flushSystemState];
        }
    }];
}

- (void)openLogs:(id)sender {
    (void)sender;
    NSString *path=[self stringForKey:@"logs_path"];
    if (path.length && ![NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:path]])
        [self showError:L(@"Unable to open logs. Try again later.")];
}

- (void)quitAndStop:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (void)beginTerminationIfIdle {
    if (!self.busy) [self runAction:@"shutdown" value:nil terminating:YES];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    if (self.readyToQuit) return NSTerminateNow;
    self.terminationPending=YES;
    [self refreshMenu];
    [self beginTerminationIfIdle];
    return NSTerminateLater;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.pollTimer invalidate];[self.systemStateTimer invalidate];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)application {
    (void)application;
    return YES;
}
@end

static XpanderMenuController *menuController;

static NSArray *MenuSnapshot(NSMenu *menu) {
    NSMutableArray *items=[NSMutableArray array];
    for(NSMenuItem *item in menu.itemArray) {
        if(item.separatorItem || item.hidden) continue;
        NSMutableDictionary *row=[@{@"title":item.title,@"checked":@(item.state==NSControlStateValueOn)} mutableCopy];
        if(item.submenu)row[@"items"]=MenuSnapshot(item.submenu);
        [items addObject:row];
    }
    return items;
}

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        MenuInspectionMode=argc==3 && !strcmp(argv[1],"--dump-menu");
        if(MenuInspectionMode) {
            NSString *language=[NSString stringWithUTF8String:argv[2]];
            if(![@[@"en",@"zh-Hant",@"system"] containsObject:language])return 2;
            [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"MSIInterfaceLanguage":language} forName:NSArgumentDomain];
        }
        NSApplication *app=NSApplication.sharedApplication;
        [app setActivationPolicy:MenuInspectionMode?NSApplicationActivationPolicyProhibited:NSApplicationActivationPolicyAccessory];
        menuController=[XpanderMenuController new];
        if(MenuInspectionMode) {
            // Inspect real NSMenu titles without opening USB, capture, observers,
            // timers or a status-bar item; no preference writes are performed.
            menuController.state=@{@"mode":@"desktop",@"desktop_fps":@60,@"desktop_quality":@1.0,@"kiosk_quality":@1.0};
            [menuController buildMenu];
            NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"language":InterfaceLanguage(),@"menu":MenuSnapshot(menuController.rootMenu)} options:NSJSONWritingPrettyPrinted error:NULL];
            if(!data)return 2;fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);return 0;
        }
        app.delegate=menuController;
        [app run];
    }
    return 0;
}

#import <AppKit/AppKit.h>
#include <math.h>

@interface XpanderMenuController : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
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
    if ([mode isEqualToString:@"desktop"]) return @"延伸桌面";
    if ([mode isEqualToString:@"stopped"]) return @"停止輸出";
    return @"讀取狀態中…";
}

- (NSString *)operationTitle {
    if (self.terminationPending) return @"正在停止輸出並結束…";
    if ([self.currentAction isEqualToString:@"resume"]) return @"正在恢復上次模式…";
    if ([self.currentAction isEqualToString:@"kiosk"]) return @"正在啟動 Kiosk…";
    if ([self.currentAction isEqualToString:@"desktop"]) return @"正在啟動延伸桌面…";
    if ([self.currentAction isEqualToString:@"stop"]) return @"正在停止輸出…";
    if ([self.currentAction isEqualToString:@"restart"]) return @"正在重新啟動輸出…";
    return @"正在套用設定…";
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
        if ([action isEqualToString:@"set-desktop-fps"]) itemTitle=[@"每秒 " stringByAppendingString:itemTitle];
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
    self.controlItems=[NSMutableArray array];
    self.modeItems=[NSMutableDictionary dictionary];
    self.fpsItems=[NSMutableDictionary dictionary];
    self.desktopQualityItems=[NSMutableDictionary dictionary];
    self.kioskQualityItems=[NSMutableDictionary dictionary];
    self.state=@{};
    self.statusItem=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
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
    self.statusHeader=[[NSMenuItem alloc] initWithTitle:@"讀取狀態中…" action:nil keyEquivalent:@""];
    self.statusHeader.enabled=NO;
    [menu addItem:self.statusHeader];
    self.errorHeader=[[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    self.errorHeader.enabled=NO;
    self.errorHeader.hidden=YES;
    [menu addItem:self.errorHeader];
    [menu addItem:NSMenuItem.separatorItem];

    NSArray *modes=@[@[@"kiosk",@"Kiosk"],@[@"desktop",@"延伸桌面"],@[@"stop",@"停止輸出"]];
    for (NSArray<NSString *> *mode in modes) {
        NSMenuItem *item=[self actionItem:mode[1] action:mode[0] value:nil];
        NSImage *radio=[NSImage imageWithSystemSymbolName:@"circle.fill" accessibilityDescription:nil];
        radio.size=NSMakeSize(8,8); radio.template=YES;
        item.onStateImage=radio;
        self.modeItems[[mode[0] isEqualToString:@"stop"] ? @"stopped" : mode[0]]=item;
        [menu addItem:item];
    }
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self settingsMenu:@"桌面更新頻率" action:@"set-desktop-fps" values:@[@"30",@"60"] items:self.fpsItems suffix:@" 次"]];
    [menu addItem:[self settingsMenu:@"桌面畫質" action:@"set-desktop-quality" values:@[@"0.75",@"0.9",@"1.0"] items:self.desktopQualityItems suffix:@""]];
    [menu addItem:[self settingsMenu:@"Kiosk 畫質" action:@"set-kiosk-quality" values:@[@"0.75",@"0.9",@"1.0"] items:self.kioskQualityItems suffix:@""]];
    NSMenuItem *testOptions=[[NSMenuItem alloc] initWithTitle:@"測試選項" action:nil keyEquivalent:@""];
    NSMenu *testMenu=[[NSMenu alloc] initWithTitle:@"測試選項"];
    testMenu.autoenablesItems=NO;
    self.testWindowItem=[self actionItem:@"顯示測試視窗" action:@"set-test-window" value:nil];
    [testMenu addItem:self.testWindowItem];
    testOptions.submenu=testMenu;
    [self.controlItems addObject:testOptions];
    [menu addItem:testOptions];
    [menu addItem:[self actionItem:@"重新啟動輸出" action:@"restart" value:nil]];
    [menu addItem:NSMenuItem.separatorItem];
    self.logsItem=[[NSMenuItem alloc] initWithTitle:@"開啟日誌" action:@selector(openLogs:) keyEquivalent:@""];
    self.logsItem.target=self;
    [menu addItem:self.logsItem];
    self.loginItem=[self actionItem:@"登入時開啟" action:@"set-login" value:nil];
    [menu addItem:self.loginItem];
    [menu addItem:NSMenuItem.separatorItem];
    self.quitItem=[[NSMenuItem alloc] initWithTitle:@"結束並停止輸出" action:@selector(quitAndStop:) keyEquivalent:@"q"];
    self.quitItem.target=self;
    [menu addItem:self.quitItem];
    self.statusItem.menu=menu;
    [self refreshMenu];
    [self runAction:@"resume" value:nil terminating:NO];
    self.pollTimer=[NSTimer timerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [self requestStatus];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}

- (void)refreshMenu {
    BOOL transition=self.terminationPending || self.busy;
    NSString *title=transition ? [self operationTitle] : [NSString stringWithFormat:@"目前模式：%@",[self modeTitle]];
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
    alert.messageText=@"無法完成操作";
    alert.informativeText=message.length ? message : @"請稍後再試，或開啟日誌查看狀態。";
    [alert addButtonWithTitle:@"好"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)executeControllerAction:(NSString *)action value:(NSString *)value
                    completion:(void (^)(NSDictionary *,NSString *,BOOL))completion {
    dispatch_async(self.commands, ^{
        NSDictionary *response=nil;
        NSString *error=nil;
        BOOL ok=NO;
        NSURL *script=[NSBundle.mainBundle URLForResource:@"controller" withExtension:@"py"];
        if (!script) {
            error=@"無法啟動面板控制服務，請重新開啟 MSI Xpander。";
        } else {
            NSTask *task=[NSTask new];
            task.executableURL=[NSURL fileURLWithPath:@"/usr/bin/python3"];
            task.arguments=value ? @[script.path,action,value] : @[script.path,action];
            NSPipe *output=[NSPipe pipe];
            task.standardOutput=output;
            task.standardError=NSFileHandle.fileHandleWithNullDevice;
            NSError *launchError=nil;
            if (![task launchAndReturnError:&launchError]) {
                error=@"無法啟動面板控制服務，請稍後再試。";
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
                    error=[detail isKindOfClass:NSString.class] && [detail length] ? detail : @"無法讀取面板狀態，請稍後再試。";
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
                            @"launch_at_login",@"test_window",@"last_error",@"logs_path"]) {
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
            if (!ok) [self showError:error];
            if (self.terminationPending) [self beginTerminationIfIdle];
        }
    }];
}

- (void)openLogs:(id)sender {
    (void)sender;
    NSString *path=[self stringForKey:@"logs_path"];
    if (path.length && ![NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:path]])
        [self showError:@"目前無法開啟日誌，請稍後再試。"];
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
    [self.pollTimer invalidate];
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)application {
    (void)application;
    return YES;
}
@end

static XpanderMenuController *menuController;

int main(int argc,const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *app=NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        menuController=[XpanderMenuController new];
        app.delegate=menuController;
        [app run];
    }
    return 0;
}

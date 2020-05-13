// Copyright 2019 Dolphin Emulator Project
// Licensed under GPLv2+
// Refer to the license.txt file included.

#import "EmulationViewController.h"

#import <utility>
#import <variant>

#import "AutoStates.h"

#import "ControllerSettingsUtils.h"

#import "Common/FileUtil.h"

#import "Core/ConfigManager.h"
#import "Core/Core.h"
#import "Core/HW/GCPad.h"
#import "Core/HW/Wiimote.h"
#import "Core/HW/WiimoteEmu/Extension/Classic.h"
#import "Core/HW/WiimoteEmu/WiimoteEmu.h"
#import "Core/HW/SI/SI.h"
#import "Core/HW/SI/SI_Device.h"
#import "Core/State.h"

#import <FirebaseAnalytics/FirebaseAnalytics.h>
#import <FirebaseCrashlytics/FirebaseCrashlytics.h>

#import "InputCommon/ControllerEmu/ControlGroup/Attachments.h"
#import "InputCommon/ControllerEmu/ControllerEmu.h"
#import "InputCommon/InputConfig.h"

#import <mach/mach.h>

#import "MainiOS.h"

#import "UICommon/GameFile.h"
#import "UICommon/GameFileCache.h"

#import "VideoCommon/RenderBase.h"

@interface EmulationViewController ()

@end

@implementation EmulationViewController

- (void)viewDidLoad
{
  [super viewDidLoad];
  
  // Setup renderer view
  if (SConfig::GetInstance().m_strVideoBackend == "Vulkan")
  {
    self.m_renderer_view = self.m_metal_view;
  }
  else
  {
    self.m_renderer_view = self.m_eagl_view;
  }
  
  [self.m_renderer_view setHidden:false];
  
  self.m_ts_active_port = -1;
  
  if (self.m_pull_down_mode != DOLTopBarPullDownModeAlwaysHidden && self.m_pull_down_mode != DOLTopBarPullDownModeAlwaysVisible)
  {
    for (GCController* controller in [GCController controllers])
    {
      if (@available(iOS 13, *))
      {
        void (^handler)(GCControllerButtonInput*, float, bool) = ^(GCControllerButtonInput* button, float value, bool pressed)
        {
          if (!pressed)
          {
            return;
          }
          
          [self topEdgeRecognized:nil];
        };
        
        if (controller.extendedGamepad != nil)
        {
          controller.extendedGamepad.buttonMenu.pressedChangedHandler = handler;
        }
        else if (controller.microGamepad != nil)
        {
          controller.extendedGamepad.buttonMenu.pressedChangedHandler = handler;
        }
      }
      else
      {
        // Fallback to controller paused handler
        controller.controllerPausedHandler = ^(GCController*)
        {
          [self topEdgeRecognized:nil];
        };
      }
    }
  }
  
  // Adjust view depending on preference
  bool do_not_raise = [[NSUserDefaults standardUserDefaults] boolForKey:@"do_not_raise_rendering_view"];
  [self.m_metal_half_constraint setActive:!do_not_raise];
  [self.m_eagl_half_constraint setActive:!do_not_raise];
  [self.m_metal_bottom_constraint setActive:do_not_raise];
  [self.m_eagl_bottom_constraint setActive:do_not_raise];
  
  // Create right bar button items
  self.m_stop_button = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemStop target:self action:@selector(StopButtonPressed:)];
  self.m_pause_button = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPause target:self action:@selector(PauseButtonPressed:)];
  self.m_play_button = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPlay target:self action:@selector(PlayButtonPressed:)];
  
  self.m_navigation_item.rightBarButtonItems = @[
    self.m_stop_button,
    self.m_pause_button
  ];
}

- (void)StartEmulation
{
  // Hack for GC IPL - the running title isn't updated on boot
  if (std::holds_alternative<BootParameters::IPL>(self->m_boot_parameters->parameters))
  {
    // Fetch the IPL region for later
    self.m_ipl_region = std::get<BootParameters::IPL>(self->m_boot_parameters->parameters).region;
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self RunningTitleUpdated];
    });
  }
  else
  {
    self.m_ipl_region = DiscIO::Region::Unknown;
  }
  
  [MainiOS startEmulationWithBootParameters:std::move(self->m_boot_parameters) viewController:self view:self.m_renderer_view];
  
  [[TCDeviceMotion shared] stopMotionUpdates];
  
  [[FIRCrashlytics crashlytics] setCustomValue:@"none" forKey:@"current-game"];
  
  dispatch_sync(dispatch_get_main_queue(), ^{
    [self performSegueWithIdentifier:@"toSoftwareTable" sender:nil];
  });
}

- (void)RunningTitleUpdated
{
  NSString* uid = nil;
  id location = nil;
  DOLAutoStateBootType boot_type = DOLAutoStateBootTypeUnknown;
  
  UICommon::GameFileCache* cache = new UICommon::GameFileCache();
  cache->Load();
  
  for (size_t i = 0; i < cache->GetSize(); i++)
  {
    std::shared_ptr<const UICommon::GameFile> game_file = cache->Get(i);
    if (SConfig::GetInstance().GetGameID() == game_file->GetGameID())
    {
      uid = CppToFoundationString(game_file->GetUniqueIdentifier());
      location = CppToFoundationString(game_file->GetFilePath());
      boot_type = DOLAutoStateBootTypeFile;
      self.m_is_wii = DiscIO::IsWii(game_file->GetPlatform());
      self.m_ipl_region = DiscIO::Region::Unknown; // Reset just in case
    }
  }
  
  if (self.m_ipl_region != DiscIO::Region::Unknown)
  {
    // We are likely in the IPL
    uid = @"GameCube Main Menu";
    location = @(static_cast<int>(self.m_ipl_region));
    boot_type = DOLAutoStateBootTypeGCIPL;
    self.m_is_wii = false;
  }
  else if (uid == nil)
  {
    uid = CppToFoundationString(SConfig::GetInstance().GetTitleDescription());
    location = [NSNumber numberWithUnsignedLongLong:SConfig::GetInstance().GetTitleID()];
    boot_type = DOLAutoStateBootTypeNand;
    self.m_is_wii = true; // assume yes since it's on NAND
    self.m_ipl_region = DiscIO::Region::Unknown; // Reset just in case
  }
  
  NSDictionary* last_game_data = @{
    @"user_facing_name": uid,
    @"boot_type": @(boot_type),
    @"location": location,
    @"state_version": @(State::GetVersion())
  };
  
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"last_game_title"];
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"last_game_path"];
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"last_game_state_version"];
  
  [[NSUserDefaults standardUserDefaults] setObject:last_game_data forKey:@"last_game_boot_info"];
  
  NSMutableArray<NSString*>* controller_list = [[NSMutableArray alloc] init];
  for (GCController* controller in [GCController controllers])
  {
    NSString* controller_type = @"Unknown";
    if (controller.extendedGamepad != nil)
    {
      controller_type = @"Extended";
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    else if (controller.gamepad != nil)
#pragma clang diagnostic pop
    {
      controller_type = @"Normal";
    }
    else if (controller.microGamepad != nil)
    {
      controller_type = @"Micro";
    }
    
    [controller_list addObject:[NSString stringWithFormat:@"%@ (%@)", [controller vendorName], controller_type]];
  }

  
  NSArray* games_array = [[NSUserDefaults standardUserDefaults] arrayForKey:@"unique_games"];
  if (![games_array containsObject:uid])
  {
    
    NSMutableArray* mutable_games_array = [games_array mutableCopy];
    [mutable_games_array addObject:uid];
    
    [[NSUserDefaults standardUserDefaults] setObject:mutable_games_array forKey:@"unique_games"];
  }
  
  [[FIRCrashlytics crashlytics] setCustomValue:uid forKey:@"current-game"];
  
  dispatch_async(dispatch_get_main_queue(), ^{
    [self PopulatePortDictionary];
    
    if (self.m_ts_active_port == -1)
    {
      if (self->m_controllers.size() != 0)
      {
        self.m_ts_active_port = self->m_controllers[0].first;
      }
    }
    
    [self ChangeVisibleTouchControllerToPort:self.m_ts_active_port];
  });
}

- (bool)prefersHomeIndicatorAutoHidden
{
  return true;
}

#pragma mark - Navigation bar

- (IBAction)topEdgeRecognized:(id)sender
{
  // Don't do anything if already visible
  if (![self.navigationController isNavigationBarHidden])
  {
    return;
  }
  
  [self UpdateNavigationBar:false];
  
  // Automatic hide after 5 seconds
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self UpdateNavigationBar:true];
  });
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures
{
  return self.m_pull_down_mode == DOLTopBarPullDownModeSwipe ? UIRectEdgeTop : UIRectEdgeNone;
}

- (bool)prefersStatusBarHidden
{
  return [self.navigationController isNavigationBarHidden];
}

- (void)UpdateNavigationBar:(bool)hidden
{
  [self.navigationController setNavigationBarHidden:hidden animated:true];
  [self setNeedsStatusBarAppearanceUpdate];
  
  // Adjust the safe area insets
  UIEdgeInsets insets = self.additionalSafeAreaInsets;
  if (hidden)
  {
    insets.top = 0;
  }
  else
  {
    // The safe area should extend behind the navigation bar
    // This makes the bar "float" on top of the content
    insets.top = -(self.navigationController.navigationBar.bounds.size.height);
  }
  
  self.additionalSafeAreaInsets = insets;
}

#pragma mark - Screen rotation specific

- (void)viewDidLayoutSubviews
{
  [[TCDeviceMotion shared] statusBarOrientationChanged];
  
  if (g_renderer)
  {
    g_renderer->ResizeSurface();
  }
}

- (void)UpdateWiiPointer
{
  if (g_renderer && [self.m_ts_active_view isKindOfClass:[TCWiiPad class]])
  {
    const MathUtil::Rectangle<int>& draw_rect = g_renderer->GetTargetRectangle();
    CGRect rect = CGRectMake(draw_rect.left, draw_rect.top, draw_rect.GetWidth(), draw_rect.GetHeight());
    
    dispatch_async(dispatch_get_main_queue(), ^{
      TCWiiPad* wii_pad = (TCWiiPad*)self.m_ts_active_view;
      [wii_pad recalculatePointerValuesWithNew_rect:rect game_aspect:g_renderer->CalculateDrawAspectRatio()];
    });
  }
}

#pragma mark - Bar buttons

- (IBAction)PauseButtonPressed:(id)sender
{
  Core::SetState(Core::State::Paused);
  
  self.m_navigation_item.rightBarButtonItems = @[
    self.m_stop_button,
    self.m_play_button
  ];
}

- (IBAction)PlayButtonPressed:(id)sender
{
  Core::SetState(Core::State::Running);
  
  self.m_navigation_item.rightBarButtonItems = @[
    self.m_stop_button,
    self.m_pause_button
  ];
}

- (IBAction)StopButtonPressed:(id)sender
{
  void (^stop)() = ^{
    [MainiOS stopEmulation];
    
    // Delete the automatic save state
    File::Delete(File::GetUserPath(D_STATESAVES_IDX) + "backgroundAuto.sav");
  };
  
  if (SConfig::GetInstance().bConfirmStop)
  {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Confirm") message:DOLocalizedString(@"Do you want to stop the current emulation?") preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"No") style:UIAlertActionStyleDefault handler:nil]];
    
    [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Yes") style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
      stop();
    }]];
    
    [self presentViewController:alert animated:true completion:nil];
  }
  else
  {
    stop();
  }
}

#pragma mark - Touchscreen Controller Switcher

- (void)PopulatePortDictionary
{
  self->m_controllers.clear();
  bool has_gccontroller_connected = false;
  
  while (SConfig::GetInstance().m_region == DiscIO::Region::Unknown)
  {
    // Spin
  }
  
  if (self.m_is_wii)
  {
    InputConfig* wii_input_config = Wiimote::GetConfig();
    for (int i = 0; i < 4; i++)
    {
      if (WiimoteCommon::GetSource(i) != WiimoteSource::Emulated) // not Emulated or not touchscreen
      {
        continue;
      }
      
      ControllerEmu::EmulatedController* controller = wii_input_config->GetController(i);
      if (![ControllerSettingsUtils IsControllerConnectedToTouchscreen:controller])
      {
        has_gccontroller_connected = true;
        continue;
      }
      
      // TODO: A better way? This will break if more settings are added to the Options group.
      ControllerEmu::ControlGroup* group = Wiimote::GetWiimoteGroup(i, WiimoteEmu::WiimoteGroup::Options);
      ControllerEmu::NumericSetting<bool>* setting = static_cast<ControllerEmu::NumericSetting<bool>*>(group->numeric_settings[3].get());
      
      TCView* pad_view;
      if (setting->GetValue())
      {
        pad_view = self.m_wii_sideways_pad;
      }
      else
      {
        ControllerEmu::Attachments* attachments = static_cast<ControllerEmu::Attachments*>(Wiimote::GetWiimoteGroup(i, WiimoteEmu::WiimoteGroup::Attachments));
        
        switch (attachments->GetSelectedAttachment())
        {
          case WiimoteEmu::ExtensionNumber::CLASSIC:
            pad_view = self.m_wii_classic_pad;
            break;
          default:
            pad_view = self.m_wii_normal_pad;
            break;
        }
      }
      
      self->m_controllers.push_back(std::make_pair(i + 4, pad_view));
    }
  }
  
  InputConfig* gc_input_config = Pad::GetConfig();
  for (int i = 0; i < 4; i++)
  {
    ControllerEmu::EmulatedController* controller = gc_input_config->GetController(i);
    if (![ControllerSettingsUtils IsControllerConnectedToTouchscreen:controller])
    {
      has_gccontroller_connected = true;
      continue;
    }
    
    SerialInterface::SIDevices device = SConfig::GetInstance().m_SIDevice[i];
    switch (device)
    {
      case SerialInterface::SIDEVICE_GC_CONTROLLER:
        self->m_controllers.push_back(std::make_pair(i, self.m_gc_pad));
      default:
        continue;
    }
  }
  
  self.m_pull_down_mode = (DOLTopBarPullDownMode)[[NSUserDefaults standardUserDefaults] integerForKey:@"top_bar_pull_down_mode"];
  
  if (has_gccontroller_connected && self.m_pull_down_mode == DOLTopBarPullDownModeSwipe)
  {
    self.m_pull_down_mode = DOLTopBarPullDownModeButton;
  }
  
  [self.navigationController setNavigationBarHidden:self.m_pull_down_mode != DOLTopBarPullDownModeAlwaysVisible animated:true];
  [self.m_edge_pan_recognizer setEnabled:self.m_pull_down_mode == DOLTopBarPullDownModeSwipe];
  [self.m_pull_down_button setHidden:self.m_pull_down_mode != DOLTopBarPullDownModeButton];
  [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
}

- (void)ChangeVisibleTouchControllerToPort:(int)port
{
  if (self.m_ts_active_view != nil)
  {
    [self.m_ts_active_view setHidden:true];
    [self.m_ts_active_view setUserInteractionEnabled:false];
  }
  
  if (port == -2)
  {
    [[TCDeviceMotion shared] stopMotionUpdates];
    self.m_ts_active_port = -2;
    self.m_ts_active_view = nil;
    
    return;
  }
  
  bool found_port = false;
  for (std::pair<int, TCView*> pair : self->m_controllers)
  {
    if (pair.first == port)
    {
      [pair.second setHidden:false];
      [pair.second setUserInteractionEnabled:true];
      [pair.second setAlpha:[[NSUserDefaults standardUserDefaults] floatForKey:@"pad_opacity_value"]];
      pair.second.m_port = port;
      
      if ([pair.second isKindOfClass:[TCWiiPad class]])
      {
        [[TCDeviceMotion shared] registerMotionHandlers];
        [[TCDeviceMotion shared] setPort:port];
        
        [self UpdateWiiPointer];
        
        // Set if the touch IR pointer should be enabled
        ControllerEmu::ControlGroup* group = Wiimote::GetWiimoteGroup(port - 4, WiimoteEmu::WiimoteGroup::IMUPoint);
        TCWiiPad* wii_pad = (TCWiiPad*)pair.second;
        [wii_pad setTouchPointerEnabled:!group->enabled];
      }
      else
      {
        [[TCDeviceMotion shared] stopMotionUpdates];
      }
      
      self.m_ts_active_port = port;
      self.m_ts_active_view = pair.second;
      
      found_port = true;
    }
  }
  
  if (!found_port)
  {
    if (self->m_controllers.size() != 0)
    {
      [self ChangeVisibleTouchControllerToPort:self->m_controllers[0].first];
      return;
    }
    
    [[TCDeviceMotion shared] stopMotionUpdates];
    self.m_ts_active_port = -1;
    self.m_ts_active_view = nil;
  }
}

#pragma mark - Top bar tutorial

- (void)viewWillAppear:(BOOL)animated
{
  NSUserDefaults* user_defaults = [NSUserDefaults standardUserDefaults];
  
  if (![user_defaults boolForKey:@"seen_top_bar_swipe_down_notice"])
  {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Tutorial" message:@"To reveal the top bar, swipe down from the top of the screen.\n\nYou can change settings and stop the emulation from the top bar." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:true completion:nil];
    
    [user_defaults setBool:true forKey:@"seen_top_bar_swipe_down_notice"];
  }
  
    [NSThread detachNewThreadSelector:@selector(StartEmulation) toTarget:self withObject:nil];
}

#pragma mark - Memory warning

- (void)didReceiveMemoryWarning
{
  // Attempt to get the process's VM info
  // https://github.com/WebKit/webkit/blob/master/Source/WTF/wtf/cocoa/MemoryFootprintCocoa.cpp
  task_vm_info_data_t vm_info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  kern_return_t result = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t) &vm_info, &count);
}

#pragma mark - Rewind segue

- (IBAction)unwindToEmulation:(UIStoryboardSegue*)segue {}

@end

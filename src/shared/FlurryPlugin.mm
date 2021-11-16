//
//  FlurryPlugin.mm
//  Flurry Plugin
//
//  Copyright (c) 2016 Corona Labs Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "CoronaRuntime.h"
#import "CoronaAssert.h"
#import "CoronaEvent.h"
#import "CoronaLua.h"
#import "CoronaLuaIOS.h"
#import "CoronaLibrary.h"

// Flurry
#import "Flurry.h"
#import "FlurryPlugin.h"

// some macros to make life easier, and code more readable
#define UTF8StringWithFormat(format, ...) [[NSString stringWithFormat:format, ##__VA_ARGS__] UTF8String]
#define MsgFormat(format, ...) [NSString stringWithFormat:format, ##__VA_ARGS__]
#define UTF8IsEqual(utf8str1, utf8str2) (strcmp(utf8str1, utf8str2) == 0)

// ----------------------------------------------------------------------------
// Plugin Constants
// ----------------------------------------------------------------------------

#define PLUGIN_NAME        "plugin.flurry.analytics"
#define PLUGIN_VERSION     "1.5.3"
#define PLUGIN_SDK_VERSION [Flurry getFlurryAgentVersion]

static const char EVENT_NAME[]    = "analyticsRequest";
static const char PROVIDER_NAME[] = "flurry";

static const char LOGLEVEL_DEFAULT[]  = "default";
static const char LOGLEVEL_DEBUG[]    = "debug";
static const char LOGLEVEL_ALL[]      = "all";

static const char PARAMS_KEY[]        = "params";
static const char ERROR_DETAILS_MSG[] = "See event.data for error details";

// analytics types
static NSString * const ANALYTICS_TYPE_BASIC = @"basic";
static NSString * const ANALYTICS_TYPE_TIMED = @"timed";

// missing Corona Event Keys
static NSString * const CORONA_EVENT_DATA_KEY = @"data";

// data keys
static NSString * const ERRORCODE_KEY  = @"errorCode";
static NSString * const REASON_KEY     = @"reason";
static NSString * const LOGEVENT_KEY   = @"event";

// event phases
static NSString * const PHASE_INIT     = @"init";
static NSString * const PHASE_FAILED   = @"failed";
static NSString * const PHASE_RECORDED = @"recorded";
static NSString * const PHASE_BEGAN    = @"began";
static NSString * const PHASE_ENDED    = @"ended";

// message constants
static NSString * const ERROR_MSG   = @"ERROR: ";
static NSString * const WARNING_MSG = @"WARNING: ";

// ----------------------------------------------------------------------------
// plugin class and delegate definitions
// ----------------------------------------------------------------------------

@interface FlurryPluginDelegate: NSObject <FlurryDelegate>

@property (nonatomic, assign) CoronaLuaRef coronaListener;         // Reference to the Lua listener
@property (nonatomic, assign) id<CoronaRuntime> coronaRuntime;     // Pointer to the Corona runtime
@property (nonatomic, assign) bool receivedInit;                   // true after 'init' event has been received from Flurry servers

- (void)dispatchLuaEvent:(NSDictionary *)dict;

@end

class FlurryPlugin
{
  public:
    typedef FlurryPlugin Self;
    
  public:
    static const char kName[];
      
  public:
    static int Open( lua_State *L );
    static int Finalizer( lua_State *L );
    static Self *ToLibrary( lua_State *L );
    
  protected:
    FlurryPlugin();
    bool Initialize( void *platformContext );
      
  public: // plugin API
    static int init( lua_State *L );
    static int logEvent( lua_State *L );
    static int startTimedEvent( lua_State *L );
    static int endTimedEvent( lua_State *L );
    static int openPrivacyDashboard( lua_State *L );
    
  private: // internal helper functions
    static void logMsg(lua_State *L, NSString *msgType,  NSString *errorMsg);
    static bool isSDKInitialized(lua_State *L);
    static void logEventWorker(lua_State *L, bool timed, bool shouldEndTimedEvent);
    
  private:
    NSString *functionSignature;              // used in logMsg to identify function
    UIViewController *coronaViewController;   // application's view controller
};

const char FlurryPlugin::kName[] = PLUGIN_NAME;
FlurryPluginDelegate *flurryPluginDelegate;                 // Flurry's delegate

// ----------------------------------------------------------------------------
// helper functions
// ----------------------------------------------------------------------------

// log message to console
void
FlurryPlugin::logMsg(lua_State *L, NSString* msgType, NSString* errorMsg)
{
  Self *context = ToLibrary(L);
  
  if (context) {
    Self& library = *context;
    
    NSString *functionID = [library.functionSignature copy];
    if (functionID.length > 0) {
      functionID = [functionID stringByAppendingString:@", "];
    }
    
    CoronaLuaLogPrefix(L, [msgType UTF8String], UTF8StringWithFormat(@"%@%@", functionID, errorMsg));
  }
}

// check if SDK calls can be made
bool
FlurryPlugin::isSDKInitialized(lua_State *L)
{
  if (flurryPluginDelegate.coronaListener == nil) {
    logMsg(L, ERROR_MSG, @"flurry.init() has not been called");
    return false;
  }
  
  if (! flurryPluginDelegate.receivedInit) {
    logMsg(L, ERROR_MSG, @"You must wait for event.phase 'init' before using the plugin");
    return false;
  }
  
  return true;
}

// get data from logEvent status
static NSMutableDictionary *
getDataFromStatus(FlurryEventRecordStatus status)
{
  NSMutableDictionary *dict;
  
  switch (status) {
    case FlurryEventRecorded:
      dict = [@{} mutableCopy]; // empty dictionary
      break;
    case FlurryEventFailed:
      dict = [@{ERRORCODE_KEY: @"0", REASON_KEY: @"failed to log event"} mutableCopy];
      break;
    case FlurryEventUniqueCountExceeded:
      dict = [@{ERRORCODE_KEY: @"1", REASON_KEY: @"unique count exceeded"} mutableCopy];
      break;
    case FlurryEventParamsCountExceeded:
      dict = [@{ERRORCODE_KEY: @"2", REASON_KEY: @"params count exceeded"} mutableCopy];
      break;
    case FlurryEventLogCountExceeded:
      dict = [@{ERRORCODE_KEY: @"3", REASON_KEY: @"log count exceeded"} mutableCopy];
      break;
    case FlurryEventLoggingDelayed:
      dict = [@{ERRORCODE_KEY: @"4", REASON_KEY: @"logging delayed"} mutableCopy];
      break;
    case FlurryEventAnalyticsDisabled:
      dict = [@{ERRORCODE_KEY: @"5", REASON_KEY: @"analytics disabled"} mutableCopy];
      break;
    default: // unknown status
      dict = [@{ERRORCODE_KEY: @"-1", REASON_KEY: @"unknown status"} mutableCopy];
  }
  
  return dict;
}

// Listener for unhandled errors
static int
flurryUnhandledErrorListener(lua_State *L)
{
  const char *errorMsg = NULL;
  const char *stackTrace = NULL;
  
  // check if the response is a table
  if (lua_type(L, 1) == LUA_TTABLE) {
    // get the error message
    lua_getfield(L, 1, "errorMessage");
    if (lua_type(L, -1) == LUA_TSTRING) {
      errorMsg = lua_tostring(L, -1);
    }
    lua_pop(L, 1);
    
    // get the stack trace
    lua_getfield(L, 1, "stackTrace");
    if (lua_type(L, -1) == LUA_TSTRING) {
      stackTrace = lua_tostring(L, -1);
    }
    lua_pop(L, 1);
    
    [Flurry logError:@(errorMsg) message:@(stackTrace) error:nil];
  }
  
  // let the event fall through to Corona
  lua_pushboolean(L, false);
  return 1;
}

// ----------------------------------------------------------------------------
// plugin implementation
// ----------------------------------------------------------------------------

int
FlurryPlugin::Open( lua_State *L )
{
  // Register __gc callback
  const char kMetatableName[] = __FILE__; // Globally unique string to prevent collision
  CoronaLuaInitializeGCMetatable( L, kMetatableName, Finalizer );
  
  void *platformContext = CoronaLuaGetContext( L );
  
  // Set library as upvalue for each library function
  Self *library = new Self;
  
  if ( library->Initialize( platformContext ) ) {
    // Functions in library
    static const luaL_Reg kFunctions[] = {
      { "init", init },
      { "logEvent", logEvent },
      { "startTimedEvent", startTimedEvent },
      { "endTimedEvent", endTimedEvent },
      { "openPrivacyDashboard", openPrivacyDashboard },
      { NULL, NULL }
    };
    
    // Register functions as closures, giving each access to the
    // 'library' instance via ToLibrary()
    {
      CoronaLuaPushUserdata( L, library, kMetatableName );
      luaL_openlib( L, kName, kFunctions, 1 ); // leave "library" on top of stack
    }
  }
  
  return 1;
}

int
FlurryPlugin::Finalizer( lua_State *L )
{
  Self *library = (Self *)CoronaLuaToUserdata(L, 1);

  // release delegate
  CoronaLuaDeleteRef(L, flurryPluginDelegate.coronaListener);
  flurryPluginDelegate = nil;
  
  delete library;
  
  return 0;
}

FlurryPlugin*
FlurryPlugin::ToLibrary( lua_State *L )
{
  // library is pushed as part of the closure
  Self *library = (Self *)CoronaLuaToUserdata( L, lua_upvalueindex( 1 ) );
  return library;
}

FlurryPlugin::FlurryPlugin()
: coronaViewController(nil)
{
}

bool
FlurryPlugin::Initialize( void *platformContext )
{
  bool result = (! coronaViewController);
  
  if (result) {
    id<CoronaRuntime> runtime = (__bridge id<CoronaRuntime>)platformContext;
    coronaViewController = runtime.appViewController;
    functionSignature = @"";
    
    // allocate and initialize the delegate
    flurryPluginDelegate = [FlurryPluginDelegate new];
    flurryPluginDelegate.coronaRuntime = runtime;
  }
  
  return result;
}

// [Lua] init( listener, options )
int
FlurryPlugin::init( lua_State *L )
{
  Self *context = ToLibrary(L);
  
  if (! context) { // abort if no valid context
    return 0;
  }
  
  Self& library = *context;
  
  // prevent init from being called twice
  if (flurryPluginDelegate.coronaListener != NULL) {
    return 0;
  }
  
  library.functionSignature = @"flurry.init(listener, options)";
  
  // check number of args
  int numArgs = lua_gettop(L);
  if (numArgs != 2) {
    logMsg(L, ERROR_MSG, MsgFormat(@"Expected 2 arguments, got %d", numArgs));
    return 0;
  }
  
  const char *apiKey = NULL;
  const char *logLevel = LOGLEVEL_DEFAULT;
  bool crashReportingEnabled = false;
  bool iapReportingEnabled = false;
  
  // Get the listener (required)
  if (CoronaLuaIsListener(L, 1, PROVIDER_NAME)) {
    flurryPluginDelegate.coronaListener = CoronaLuaNewRef(L, 1);
  }
  else {
    logMsg(L, ERROR_MSG, MsgFormat(@"Listener expected, got: %s", luaL_typename(L, 1)));
    return 0;
  }
  
  // check for options table (required)
  if (lua_type(L, 2) == LUA_TTABLE) {
    // traverse and validate all the options
    for (lua_pushnil(L); lua_next(L, 2) != 0; lua_pop(L, 1)) {
      const char *key = lua_tostring(L, -2);
      
      if (UTF8IsEqual(key, "apiKey")) {
        if (lua_type(L, -1) == LUA_TSTRING) {
          apiKey = lua_tostring(L, -1);
        }
        else {
          logMsg(L, ERROR_MSG, MsgFormat(@"options.apiKey (string) expected, got %s", luaL_typename(L, -1)));
          return 0;
        }
      }
      else if (UTF8IsEqual(key, "logLevel")) {
        if (lua_type(L, -1) == LUA_TSTRING) {
          logLevel = lua_tostring(L, -1);
        }
        else {
          logMsg(L, ERROR_MSG, MsgFormat(@"options.logLevel (string) expected, got %s", luaL_typename(L, -1)));
          return 0;
        }
      }
      else if (UTF8IsEqual(key, "crashReportingEnabled")) {
        if (lua_type(L, -1) == LUA_TBOOLEAN) {
          crashReportingEnabled = lua_toboolean(L, -1);
        }
        else {
          logMsg(L, ERROR_MSG, MsgFormat(@"options.crashReportingEnabled (boolean) expected, got %s", luaL_typename(L, -1)));
          return 0;
        }
      }
      else if (UTF8IsEqual(key, "IAPReportingEnabled")) { // iOS only feature
        if (lua_type(L, -1) == LUA_TBOOLEAN) {
          iapReportingEnabled = lua_toboolean(L, -1);
        }
        else {
          logMsg(L, ERROR_MSG, MsgFormat(@"options.IAPReportingEnabled (boolean) expected, got %s", luaL_typename(L, -1)));
          return 0;
        }
      }
      else {
        logMsg(L, ERROR_MSG, MsgFormat(@"Invalid option '%s'", key));
        return 0;
      }
    }
  }
  else {
    logMsg(L, ERROR_MSG, MsgFormat(@"options table expected, got %s", luaL_typename(L, 2)));
    return 0;
  }
  
  // validation
  if (apiKey == NULL) {
    logMsg(L, ERROR_MSG, @"apiKey is missing");
    return 0;
  }
  
  // log the plugin version to device console
  NSLog(@"%s: %s (SDK: %@)", PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_SDK_VERSION);

#if TARGET_OS_IOS
  // initialize session builder for setting up SDK properties
  FlurrySessionBuilder *sessionBuilder = [FlurrySessionBuilder new];
  
  // set log level
  if (UTF8IsEqual(logLevel, LOGLEVEL_DEBUG)) {
    [sessionBuilder withLogLevel:FlurryLogLevelDebug];
  }
  else if (UTF8IsEqual(logLevel, LOGLEVEL_ALL)) {
    [sessionBuilder withLogLevel:FlurryLogLevelAll];
  }
  else { // set to default logging level
    [sessionBuilder withLogLevel:FlurryLogLevelCriticalOnly];
  }
  
  [sessionBuilder withCrashReporting:crashReportingEnabled];
  [sessionBuilder withIAPReportingEnabled:iapReportingEnabled];
  [Flurry setDelegate:flurryPluginDelegate];
  [Flurry startSession:@(apiKey) withSessionBuilder:sessionBuilder];
#else // tvOS
  // set log level
  if (UTF8IsEqual(logLevel, LOGLEVEL_DEBUG)) {
    [Flurry setLogLevel:FlurryLogLevelDebug];
  }
  else if (UTF8IsEqual(logLevel, LOGLEVEL_ALL)) {
    [Flurry setLogLevel:FlurryLogLevelAll];
  }
  else { // set to default logging level
    [Flurry setLogLevel:FlurryLogLevelCriticalOnly];
  }
  
  [Flurry setDelegate:flurryPluginDelegate];
  [Flurry startSession:@(apiKey)];
#endif
  
  if (crashReportingEnabled) {
    // set up a callback for unhandled errors
    lua_getglobal(L, "Runtime");                                  // push Runtime
    lua_getfield(L, -1, "addEventListener");                      // push function name
    lua_pushvalue(L, -2);                                         // push copy of Runtime   (1st arg must be self)
    lua_pushstring(L, "unhandledError");                          // push event name        (2nd arg)
    lua_pushcfunction(L, flurryUnhandledErrorListener);           // push listener          (3rd arg)
    lua_call(L, 3, 0);                                            // call function (pops function + 3 args, returns nothing)
    lua_pop(L, 1);                                                // pop Runtime
  }
  
  return 0;
}

// Shared worker function called by logEvent, logTimedEvent and endTimedEvent
void
FlurryPlugin::logEventWorker(lua_State *L, bool timed, bool shouldEndTimedEvent) {

  // check number of args
  int numArgs = lua_gettop(L);
  if ((numArgs < 1) || (numArgs > 2)) {
    logMsg(L, ERROR_MSG, MsgFormat(@"Expected 1 or 2 arguments, got %d", numArgs));
    return;
  }

  const char *eventName;
  NSMutableDictionary *params;
  
  // Get the event name (required)
  if (lua_type(L, 1) == LUA_TSTRING) {
    eventName = lua_tostring(L, 1);
  }
  else {
    logMsg(L, ERROR_MSG, MsgFormat(@"eventName (string) expected, got %s", luaL_typename(L, 1)));
    return;
  }
  
  // get params table (optional)
  if (! lua_isnoneornil(L, 2)) {
    if (lua_type(L, 2) == LUA_TTABLE) {
      params = [CoronaLuaCreateDictionary(L, 2) mutableCopy];
      
      for (NSString *key in params) { // make sure that all values are strings
        id value = [params objectForKey:key];
        
        if (! [value isKindOfClass:[NSString class]]) {
          logMsg(L, ERROR_MSG, MsgFormat(@"Options value for key '%@' must be a string", key));
          return;
        }
      }
    }
    else {
      logMsg(L, ERROR_MSG, MsgFormat(@"Options table expected got %s", luaL_typename(L, 2)));
      return;
    }
  }
  else { // create empty dictionary
    params = [@{} mutableCopy];
  }
  
  FlurryEventRecordStatus status;
  NSMutableDictionary *eventData;
  
  if (shouldEndTimedEvent) {
    [Flurry endTimedEvent:[NSString stringWithUTF8String:eventName] withParameters:params];
    eventData = [@{} mutableCopy];
  }
  else {
    // do we have any optional params?
    if (params.count > 0) {
      status = [Flurry logEvent:@(eventName) withParameters:params timed:timed];
    }
    else {
      status = [Flurry logEvent:@(eventName) timed:timed];
    }
    
    eventData = getDataFromStatus(status);
  }
  
  // error condition if dictionary is not empty
  bool isError = (eventData.count > 0);
  
  // add logEvent entry to data
  eventData[LOGEVENT_KEY] = @(eventName);
  
  // add params to data (if present)
  if (params.count > 0) {
    eventData[@(PARAMS_KEY)] = params;
  }
  
  // set analytics type
  NSString *analyticsType = (timed) ? ANALYTICS_TYPE_TIMED : ANALYTICS_TYPE_BASIC;
  
  // set event phase
  NSString *eventPhase = PHASE_RECORDED;
  
  if (shouldEndTimedEvent) {
    eventPhase = PHASE_ENDED;
  }
  else if (timed) {
    eventPhase = PHASE_BEGAN;
  }
  
  // create event data
  NSDictionary *coronaEvent;
  
  if (isError) {
    coronaEvent = @{
    
      @(CoronaEventPhaseKey()) : PHASE_FAILED,
      @(CoronaEventTypeKey()) : analyticsType,
      CORONA_EVENT_DATA_KEY : eventData,
      @(CoronaEventIsErrorKey()) : @(true),
      @(CoronaEventResponseKey()) : @(ERROR_DETAILS_MSG)
    };
  }
  else {
    coronaEvent = @{
      @(CoronaEventPhaseKey()) : eventPhase,
      @(CoronaEventTypeKey()) : analyticsType,
      CORONA_EVENT_DATA_KEY : eventData
    };
  }
  
  [flurryPluginDelegate dispatchLuaEvent:coronaEvent];
}

// [Lua] logEvent(event [, options])
int
FlurryPlugin::logEvent( lua_State *L )
{
  Self *context = ToLibrary(L);
  
  if (context) {
    Self& library = *context;
    
    if (isSDKInitialized(L)) {
      library.functionSignature = @"flurry.logEvent(event [, options])";
      logEventWorker(L, false, false); // lua_State, isTimed, shouldEndTimedEvent
    }
  }
  
  return 0;
}

// [Lua] logTimedEvent(event [, options])
int
FlurryPlugin::startTimedEvent(lua_State *L)
{
  Self *context = ToLibrary(L);
  
  if (context) {
    Self& library = *context;
    
    if (isSDKInitialized(L)) {
      library.functionSignature = @"flurry.startTimedEvent(event [, options])";
      logEventWorker(L, true, false); // lua_State, isTimed, shouldEndTimedEvent
    }
  }
  
  return 0;
}

// [Lua] endTimedEvent(event [, options])
int
FlurryPlugin::endTimedEvent(lua_State *L)
{
  Self *context = ToLibrary(L);
  
  if (context) {
    Self& library = *context;
    
    if (isSDKInitialized(L)) {
      library.functionSignature = @"flurry.endTimedEvent(event [, options])";
      logEventWorker(L, true, true); // lua_State, isTimed, shouldEndTimedEvent
    }
  }
  return 0;
}

// [Lua] openPrivacyDashboard()
int
FlurryPlugin::openPrivacyDashboard(lua_State *L)
{
    Self *context = ToLibrary(L);

    if (context) {
        Self& library = *context;

        if (isSDKInitialized(L)) {
            library.functionSignature = @"flurry.openPrivacyDashboard()";
            dispatch_async(dispatch_get_main_queue(), ^{
                [Flurry openPrivacyDashboard:nil];
            });
        }
    }
    return 0;
}

// ============================================================================
// delegate implementation
// ============================================================================

@implementation FlurryPluginDelegate

- (instancetype)init {
  if (self = [super init]) {
    self.coronaListener = NULL;
    self.coronaRuntime = NULL;
    self.receivedInit = false;
  }
  
  return self;
}

// dispatch a new Lua event
- (void)dispatchLuaEvent:(NSDictionary *)dict
{
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    lua_State *L = self.coronaRuntime.L;
    CoronaLuaRef coronaListener = self.coronaListener;
    bool hasErrorKey = false;
    
    // create new event
    CoronaLuaNewEvent(L, EVENT_NAME);
    
    for (NSString *key in dict) {
      CoronaLuaPushValue(L, [dict valueForKey:key]);
      lua_setfield(L, -2, key.UTF8String);
      
      if (! hasErrorKey) {
        hasErrorKey = [key isEqualToString:@(CoronaEventIsErrorKey())];
      }
    }
    
    // add error key if not in dict
    if (! hasErrorKey) {
      lua_pushboolean(L, false);
      lua_setfield(L, -2, CoronaEventIsErrorKey());
    }
    
    // add provider
    lua_pushstring(L, PROVIDER_NAME );
    lua_setfield(L, -2, CoronaEventProviderKey());
    
    CoronaLuaDispatchEvent(L, coronaListener, 0);
  }];
}

// -----------------------------------------
// Callbacks
// -----------------------------------------

- (void)flurrySessionDidCreateWithInfo:(NSDictionary *)info
{
  self.receivedInit = true;
  
  // Android doesn't report api key in init. remove it from the dictionary for consistency
  NSMutableDictionary *flurryData = [info mutableCopy];
  [flurryData removeObjectForKey:@"apiKey"];
  
  // create corona event
  NSDictionary *coronaEvent = @{
    @(CoronaEventPhaseKey()) : PHASE_INIT,
    CORONA_EVENT_DATA_KEY : flurryData
  };
  [self dispatchLuaEvent:coronaEvent];
}

@end

CORONA_EXPORT int luaopen_plugin_flurry_analytics( lua_State *L )
{
  return FlurryPlugin::Open( L );
}

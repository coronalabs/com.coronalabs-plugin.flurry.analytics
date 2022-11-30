//
// LuaLoader.java
// Flurry Plugin
//
// Copyright (c) 2016 CoronaLabs inc. All rights reserved.
//

package plugin.flurry.analytics;

// imports

import com.ansca.corona.CoronaActivity;
import com.ansca.corona.CoronaLua;
import com.ansca.corona.CoronaLuaEvent;
import com.ansca.corona.CoronaRuntimeTask;
import com.ansca.corona.CoronaRuntimeTaskDispatcher;
import com.ansca.corona.CoronaEnvironment;
import com.ansca.corona.CoronaRuntime;
import com.ansca.corona.CoronaRuntimeListener;

import com.flurry.android.FlurryPrivacySession;
import com.naef.jnlua.LuaState;
import com.naef.jnlua.JavaFunction;
import com.naef.jnlua.LuaType;
import com.naef.jnlua.NamedJavaFunction;

import java.util.Hashtable;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

import android.util.Log;

// Flurry imports
import com.flurry.android.FlurryAgent;
import com.flurry.android.FlurryAgentListener;
import com.flurry.android.FlurryEventRecordStatus;

/**
 * Implements the Lua interface for the Flurry Plugin.
 * <p>
 * Only one instance of this class will be created by Corona for the lifetime of the application.
 * This instance will be re-used for every new Corona activity that gets created.
 */
public class LuaLoader implements JavaFunction, CoronaRuntimeListener {
    private static final String PLUGIN_NAME = "plugin.flurry.analytics";
    private static final String PLUGIN_VERSION = "1.5.4";
    private static final String PLUGIN_SDK_VERSION = FlurryAgent.getReleaseVersion();

    private static final String EVENT_NAME = "analyticsRequest";
    private static final String PROVIDER_NAME = "flurry";

    // analytics types
    private static final String ANALYTICS_TYPE_BASIC = "basic";
    private static final String ANALYTICS_TYPE_TIMED = "timed";

    // Log levels
    private static final String LOGLEVEL_DEFAULT = "default";
    private static final String LOGLEVEL_DEBUG = "debug";
    private static final String LOGLEVEL_ALL = "all";

    // data keys
    private static final String ERRORCODE_KEY = "errorCode";
    private static final String REASON_KEY = "reason";
    private static final String LOGEVENT_KEY = "event";

    // add missing event keys
    private static final String EVENT_PHASE_KEY = "phase";
    private static final String EVENT_DATA_KEY = "data";
    private static final String EVENT_TYPE_KEY = "type";

    private static final String PARAMS_KEY = "params";
    private static final String SESSION_ID_KEY = "sessionId";
    private static final String ERROR_DETAILS_MSG = "See event.data for error details";

    // callback delegate event phases
    private static final String PHASE_INIT = "init";
    private static final String PHASE_FAILED = "failed";
    private static final String PHASE_RECORDED = "recorded";
    private static final String PHASE_BEGAN = "began";
    private static final String PHASE_ENDED = "ended";

    // message constants
    private static final String CORONA_TAG = "Corona";
    private static final String ERROR_MSG = "ERROR: ";
    private static final String WARNING_MSG = "WARNING: ";

    private static int coronaListener = CoronaLua.REFNIL;
    private static CoronaRuntimeTaskDispatcher coronaRuntimeTaskDispatcher = null;

    private static boolean hasReceivedInit = false;                     // true after 'init' event has been received from Flurry servers
    private static ScheduledExecutorService initLoopExecutor = null;    // monitors when an 'init' event can be sent
    private static boolean isCrashReportingEnabled = false;
    private static FlurryUnhandledErrorListener flurryUnhandledErrorListener = null;
    private static String functionSignature = "";

    /**
     * <p>
     * Note that a new LuaLoader instance will not be created for every CoronaActivity instance.
     * That is, only one instance of this class will be created for the lifetime of the application process.
     * This gives a plugin the option to do operations in the background while the CoronaActivity is destroyed.
     */
    @SuppressWarnings("unused")
    public LuaLoader() {
        // Set up this plugin to listen for Corona runtime events to be received by methods
        // onLoaded(), onStarted(), onSuspended(), onResumed(), and onExiting().
        CoronaEnvironment.addRuntimeListener(this);
    }

    /**
     * Called when this plugin is being loaded via the Lua require() function.
     * <p>
     * Note that this method will be called every time a new CoronaActivity has been launched.
     * This means that you'll need to re-initialize this plugin here.
     * <p>
     * Warning! This method is not called on the main UI thread.
     *
     * @param L Reference to the Lua state that the require() function was called from.
     * @return Returns the number of values that the require() function will return.
     * <p>
     * Expected to return 1, the library that the require() function is loading.
     */
    @Override
    public int invoke(LuaState L) {
        // Register this plugin into Lua with the following functions.
        NamedJavaFunction[] luaFunctions = new NamedJavaFunction[]{
                new Init(),
                new LogEvent(),
                new StartTimedEvent(),
                new EndTimedEvent(),
                new OpenPrivacyDashboard(),
        };
        String libName = L.toString(1);
        L.register(libName, luaFunctions);

        // Returning 1 indicates that the Lua require() function will return the above Lua library.
        return 1;
    }

    /**
     * Called after the Corona runtime has been created and just before executing the "main.lua" file.
     * <p>
     * Warning! This method is not called on the main thread.
     *
     * @param runtime Reference to the CoronaRuntime object that has just been loaded/initialized.
     *                Provides a LuaState object that allows the application to extend the Lua API.
     */
    @Override
    public void onLoaded(CoronaRuntime runtime) {
        // Note that this method will not be called the first time a Corona activity has been launched.
        // This is because this listener cannot be added to the CoronaEnvironment until after
        // this plugin has been required-in by Lua, which occurs after the onLoaded() event.
        // However, this method will be called when a 2nd Corona activity has been created.

        if (coronaRuntimeTaskDispatcher == null) {
            coronaRuntimeTaskDispatcher = new CoronaRuntimeTaskDispatcher(runtime);
        }
    }

    /**
     * Called just after the Corona runtime has executed the "main.lua" file.
     * <p>
     * Warning! This method is not called on the main thread.
     *
     * @param runtime Reference to the CoronaRuntime object that has just been started.
     */
    @Override
    public void onStarted(CoronaRuntime runtime) {
    }

    /**
     * Called just after the Corona runtime has been suspended which pauses all rendering, audio, timers,
     * and other Corona related operations. This can happen when another Android activity (ie: window) has
     * been displayed, when the screen has been powered off, or when the screen lock is shown.
     * <p>
     * Warning! This method is not called on the main thread.
     *
     * @param runtime Reference to the CoronaRuntime object that has just been suspended.
     */
    @Override
    public void onSuspended(CoronaRuntime runtime) {
    }

    /**
     * Called just after the Corona runtime has been resumed after a suspend.
     * <p>
     * Warning! This method is not called on the main thread.
     *
     * @param runtime Reference to the CoronaRuntime object that has just been resumed.
     */
    @Override
    public void onResumed(CoronaRuntime runtime) {
    }

    /**
     * Called just before the Corona runtime terminates.
     * <p>
     * This happens when the Corona activity is being destroyed which happens when the user presses the Back button
     * on the activity, when the native.requestExit() method is called in Lua, or when the activity's finish()
     * method is called. This does not mean that the application is exiting.
     * <p>
     * Warning! This method is not called on the main thread.
     *
     * @param runtime Reference to the CoronaRuntime object that is being terminated.
     */
    @Override
    public void onExiting(final CoronaRuntime runtime) {
        LuaState L = runtime.getLuaState();

        // reset class variables
        CoronaLua.deleteRef(L, coronaListener);
        coronaListener = CoronaLua.REFNIL;
        coronaRuntimeTaskDispatcher = null;

        isCrashReportingEnabled = false;
        flurryUnhandledErrorListener = null;
        functionSignature = "";
        hasReceivedInit = false;
        initLoopExecutor = null;
    }

    // --------------------------------------------------------------------------
    // helper functions
    // --------------------------------------------------------------------------

    // log message to console
    private void logMsg(String msgType, String errorMsg) {
        String functionID = functionSignature;
        if (!functionID.isEmpty()) {
            functionID += ", ";
        }

        Log.i(CORONA_TAG, msgType + functionID + errorMsg);
    }

    // return true if SDK is properly initialized
    private boolean isSDKInitialized() {
        if (coronaListener == CoronaLua.REFNIL) {
            logMsg(ERROR_MSG, "You must call flurry.init() before calling other Flurry API functions");
            return false;
        }

        if (!hasReceivedInit) {
            logMsg(ERROR_MSG, "You must wait for the 'init' event before calling other Flurry API functions");
            return false;
        }

        return true;
    }

    // return map for flurry return status (used in lua event data)
    private Map<String, Object> getDataFromStatus(FlurryEventRecordStatus status) {
        Map<String, Object> dict = new Hashtable<>();

        switch (status) {
            case kFlurryEventRecorded:
                // empty map
                break;

            case kFlurryEventFailed:
                dict.put(ERRORCODE_KEY, "0");
                dict.put(REASON_KEY, "failed to log event");
                break;

            case kFlurryEventUniqueCountExceeded:
                dict.put(ERRORCODE_KEY, "1");
                dict.put(REASON_KEY, "unique count exceeded");
                break;

            case kFlurryEventParamsCountExceeded:
                dict.put(ERRORCODE_KEY, "2");
                dict.put(REASON_KEY, "params count exceeded");
                break;

            case kFlurryEventLogCountExceeded:
                dict.put(ERRORCODE_KEY, "3");
                dict.put(REASON_KEY, "log count exceeded");
                break;

            case kFlurryEventLoggingDelayed:
                dict.put(ERRORCODE_KEY, "4");
                dict.put(REASON_KEY, "logging delayed");
                break;

            case kFlurryEventAnalyticsDisabled:
                dict.put(ERRORCODE_KEY, "5");
                dict.put(REASON_KEY, "analytics disabled");
                break;

            default:
                dict.put(ERRORCODE_KEY, "-1");
                dict.put(REASON_KEY, "unknown status");
        }

        return dict;
    }

    // dispatch init event (separate function as it's called from multiple places)
    private void dispatchInitEvent() {
        String sessionId = FlurryAgent.getSessionId();

        // dispatch event only if session id exists ("0" means no active session)
        if ((sessionId != null) && (!sessionId.equals("0")) && (!hasReceivedInit)) {
            hasReceivedInit = true;

            // create data
            Map<String, Object> eventData = new Hashtable<>();
            eventData.put(SESSION_ID_KEY, sessionId);

            // create event
            Map<String, Object> coronaEvent = new Hashtable<>();
            coronaEvent.put(EVENT_PHASE_KEY, PHASE_INIT);
            coronaEvent.put(EVENT_DATA_KEY, eventData);

            dispatchLuaEvent(coronaEvent);
        }
    }

    // dispatch a Lua event to our callback (dynamic handling of properties through map)
    private void dispatchLuaEvent(final Map<String, Object> event) {
        if (coronaRuntimeTaskDispatcher != null) {
            coronaRuntimeTaskDispatcher.send(new CoronaRuntimeTask() {
                public void executeUsing(CoronaRuntime runtime) {
                    try {
                        LuaState L = runtime.getLuaState();
                        CoronaLua.newEvent(L, EVENT_NAME);
                        boolean hasErrorKey = false;

                        // add event parameters from map
                        for (String key : event.keySet()) {
                            CoronaLua.pushValue(L, event.get(key));           // push value
                            L.setField(-2, key);                              // push key

                            if (!hasErrorKey) {
                                hasErrorKey = key.equals(CoronaLuaEvent.ISERROR_KEY);
                            }
                        }

                        // add error key if not in map
                        if (!hasErrorKey) {
                            L.pushBoolean(false);
                            L.setField(-2, CoronaLuaEvent.ISERROR_KEY);
                        }

                        // add provider
                        L.pushString(PROVIDER_NAME);
                        L.setField(-2, CoronaLuaEvent.PROVIDER_KEY);

                        CoronaLua.dispatchEvent(L, coronaListener, 0);
                    } catch (Exception ex) {
                        ex.printStackTrace();
                    }
                }
            });
        }
    }

    private class FlurryUnhandledErrorListener implements JavaFunction {
        public FlurryUnhandledErrorListener() {
        }

        /**
         * This method is called when the Lua function is called.
         * <p>
         * Warning! This method is not called on the main UI thread.
         *
         * @param luaState Reference to the Lua state.
         *                 Needed to retrieve the Lua function's parameters and to return values back to Lua.
         * @return Returns the number of values to be returned by the Lua function.
         */
        @Override
        public int invoke(LuaState luaState) {
            String errorMsg = null;
            String stackTrace = null;

            // check if the response is a table
            if (luaState.type(1) == LuaType.TABLE) {
                // get the error message
                luaState.getField(1, "errorMessage");
                if (luaState.type(-1) == LuaType.STRING) {
                    errorMsg = luaState.toString(-1);
                }
                luaState.pop(1);

                // get the stack trace
                luaState.getField(1, "stackTrace");
                if (luaState.type(-1) == LuaType.STRING) {
                    stackTrace = luaState.toString(-1);
                }
                luaState.pop(1);

                FlurryAgent.onError(errorMsg, stackTrace, (Throwable) null);
            }

            // let the event fall through to Corona
            luaState.pushBoolean(false);
            return 1;
        }
    }

    // Worker function for logEvent, logTimedEvent and endTimedEvent
    final class LogEventWorker {
        LuaState luaState = null;
        private Boolean isTimed = false;
        private Boolean shouldEndTimedEvent = false;

        public LogEventWorker(LuaState luaState, Boolean isTimed, Boolean shouldEndTimedEvent) {
            this.luaState = luaState;
            this.isTimed = isTimed;
            this.shouldEndTimedEvent = shouldEndTimedEvent;
        }

        public void doWork() {
            if (!isSDKInitialized()) {
                return;
            }

            // check number of args
            int nargs = luaState.getTop();
            if ((nargs < 1) || (nargs > 2)) {
                logMsg(ERROR_MSG, "Expected 1 or 2 arguments, got " + nargs);
                return;
            }

            Map<String, String> params = new Hashtable<>();
            String eventName;

            final LuaState L = luaState;

            // Get the event name
            if (L.type(1) == LuaType.STRING) {
                eventName = L.toString(1);
            } else {
                logMsg(ERROR_MSG, "eventName (string) expected, got " + L.typeName(1));
                return;
            }

            // get params table (optional)
            if (!L.isNoneOrNil(2)) {
                if (L.type(2) == LuaType.TABLE) {
                    Map<Object, Object> paramsData = CoronaLua.toHashtable(L, 2);

                    // make sure all values are strings
                    for (Object key : paramsData.keySet()) {
                        Object value = paramsData.get(key);
                        if (!(value instanceof String)) {
                            logMsg(ERROR_MSG, "Options value for key '" + key + "' must be a string");
                            return;
                        }
                        params.put((String) key, (String) value);
                    }
                } else {
                    logMsg(ERROR_MSG, "Options table expected, got " + L.typeName(2));
                    return;
                }
            }

            FlurryEventRecordStatus status;
            Map<String, Object> eventData;

            if (shouldEndTimedEvent) {
                FlurryAgent.endTimedEvent(eventName, params);
                eventData = new Hashtable<>();
            } else {
                // do we have optional params?
                if (params.size() > 0) {
                    status = FlurryAgent.logEvent(eventName, params, isTimed);
                } else {
                    status = FlurryAgent.logEvent(eventName, isTimed);
                }

                eventData = getDataFromStatus(status);
            }

            // error condition if dictionary is not empty
            Boolean isError = (eventData.size() > 0);

            // add logEvent entry to data
            eventData.put(LOGEVENT_KEY, eventName);

            // add params to data
            if (params.size() > 0) {
                eventData.put(PARAMS_KEY, params);
            }

            // set analytics type
            String analyticsType = (isTimed) ? ANALYTICS_TYPE_TIMED : ANALYTICS_TYPE_BASIC;

            // set event phase
            String eventPhase = PHASE_RECORDED;

            if (shouldEndTimedEvent) {
                eventPhase = PHASE_ENDED;
            } else if (isTimed) {
                eventPhase = PHASE_BEGAN;
            }

            // create event data
            Map<String, Object> coronaEvent = new Hashtable<>();
            coronaEvent.put(EVENT_TYPE_KEY, analyticsType);
            coronaEvent.put(EVENT_DATA_KEY, eventData);

            if (isError) {
                coronaEvent.put(EVENT_PHASE_KEY, PHASE_FAILED);
                coronaEvent.put(CoronaLuaEvent.ISERROR_KEY, true);
                coronaEvent.put(CoronaLuaEvent.RESPONSE_KEY, ERROR_DETAILS_MSG);
            } else {
                coronaEvent.put(EVENT_PHASE_KEY, eventPhase);
            }

            dispatchLuaEvent(coronaEvent);
        }
    }

    // -------------------------------------------------------
    // plugin implementation
    // -------------------------------------------------------

    // [Lua] init(listener, params)
    private class Init implements NamedJavaFunction {
        /**
         * Gets the name of the Lua function as it would appear in the Lua script.
         *
         * @return Returns the name of the custom Lua function.
         */
        @Override
        public String getName() {
            return "init";
        }

        /**
         * This method is called when the Lua function is called.
         * <p>
         * Warning! This method is not called on the main UI thread.
         *
         * @param luaState Reference to the Lua state.
         *                 Needed to retrieve the Lua function's parameters and to return values back to Lua.
         * @return Returns the number of values to be returned by the Lua function.
         */
        @Override
        public int invoke(final LuaState luaState) {
            // bail if init() has already been called
            if (coronaListener != CoronaLua.REFNIL) {
                return 0;
            }

            // set data for logging function
            functionSignature = "flurry.init(listener, options)";

            // check number of args
            int nargs = luaState.getTop();
            if (nargs != 2) {
                logMsg(ERROR_MSG, "Expected 2 arguments, got " + nargs);
                return 0;
            }

            String apiKey = null;
            String logLevel = LOGLEVEL_DEFAULT;

            // Get the listener (required)
            if (CoronaLua.isListener(luaState, 1, PROVIDER_NAME)) {
                coronaListener = CoronaLua.newRef(luaState, 1);
            } else {
                logMsg(ERROR_MSG, "Listener expected, got: " + luaState.typeName(1));
                return 0;
            }

            // check for options table (required)
            if (luaState.type(2) == LuaType.TABLE) {
                // traverse and verify all options
                for (luaState.pushNil(); luaState.next(2); luaState.pop(1)) {
                    String key = luaState.toString(-2);

                    if (key.equals("apiKey")) {
                        if (luaState.type(-1) == LuaType.STRING) {
                            apiKey = luaState.toString(-1);
                        } else {
                            logMsg(ERROR_MSG, "options.apiKey (string) expected, got " + luaState.typeName(-1));
                            return 0;
                        }
                    } else if (key.equals("logLevel")) {
                        if (luaState.type(-1) == LuaType.STRING) {
                            logLevel = luaState.toString(-1);
                        } else {
                            logMsg(ERROR_MSG, "options.logLevel (string) expected, got " + luaState.typeName(-1));
                            return 0;
                        }
                    } else if (key.equals("crashReportingEnabled")) {
                        if (luaState.type(-1) == LuaType.BOOLEAN) {
                            isCrashReportingEnabled = luaState.toBoolean(-1);
                        } else {
                            logMsg(ERROR_MSG, "options.crashReportingEnabled (boolean) expected, got " + luaState.typeName(-1));
                            return 0;
                        }
                    } else if (key.equals("IAPReportingEnabled")) {
                        // NOP (iOS only)
                        // Automatic IAP logging not available on Android
                        // TODO: Implement logPurchase() for manual reporting
                    } else {
                        logMsg(ERROR_MSG, "Invalid option '" + key + "'");
                        return 0;
                    }
                }
            } else {
                logMsg(ERROR_MSG, "options table expected, got " + luaState.typeName(2));
                return 0;
            }

            // validation
            if (apiKey == null) {
                logMsg(ERROR_MSG, "apiKey is missing");
                return 0;
            }

            final CoronaActivity coronaActivity = CoronaEnvironment.getCoronaActivity();
            final Boolean crashReportingEnabled = isCrashReportingEnabled;
            final String fLogLevel = logLevel;
            final String fApiKey = apiKey;

            if (coronaActivity != null) {
                coronaActivity.runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        // Log plugin version to device log
                        Log.i(CORONA_TAG, PLUGIN_NAME + ": " + PLUGIN_VERSION + " (SDK: " + PLUGIN_SDK_VERSION + ")");

                        FlurryAgent.Builder builder = new FlurryAgent.Builder();
                        builder = builder.withLogEnabled(true);

                        switch (fLogLevel) {
                            case LOGLEVEL_DEBUG:
                                builder = builder.withLogLevel(Log.DEBUG);
                                break;
                            case LOGLEVEL_ALL:
                                builder = builder.withLogLevel(Log.VERBOSE);
                                break;
                            default:
                                builder = builder.withLogLevel(Log.INFO);
                                break;
                        }

                        builder = builder.withCaptureUncaughtExceptions(crashReportingEnabled);
                        builder = builder.withContinueSessionMillis(5000);
                        builder = builder.withListener(new CoronaFlurryDelegate()); // cannot omit the listener even though it isn't used
                        builder.build(coronaActivity, fApiKey);

                        // Send 'init' event when a valid sessionId is available.
                        // We can't use the onSessionStarted listener due to timing issues with Flurry's automatic
                        // session management and Corona's plugin initialization.
                        // (sometimes onSessionStarted is called before Corona's runtime task dispatcher is ready to receive events)
                        initLoopExecutor = Executors.newSingleThreadScheduledExecutor();
                        initLoopExecutor.scheduleAtFixedRate(new Runnable() {
                            @Override
                            public void run() {
                                String sessionId = FlurryAgent.getSessionId();
                                if ((sessionId != null) && (!sessionId.equals("0"))) {
                                    dispatchInitEvent();
                                    initLoopExecutor.shutdown();
                                }
                            }
                        }, 0, 1, TimeUnit.SECONDS);
                    }
                });
            }

            return 0;
        }
    }

    // [Lua] logEvent(event [, params])
    private class LogEvent implements NamedJavaFunction {
        /**
         * Gets the name of the Lua function as it would appear in the Lua script.
         *
         * @return Returns the name of the custom Lua function.
         */
        @Override
        public String getName() {
            return "logEvent";
        }

        /**
         * This method is called when the Lua function is called.
         * <p>
         * Warning! This method is not called on the main UI thread.
         *
         * @param luaState Reference to the Lua state.
         *                 Needed to retrieve the Lua function's parameters and to return values back to Lua.
         * @return Returns the number of values to be returned by the Lua function.
         */
        @Override
        public int invoke(LuaState luaState) {
            functionSignature = "flurry.logEvent(event, options)";
            LogEventWorker worker = new LogEventWorker(luaState, false, false); // luaState, isTimed, shouldEndTimedEvent
            worker.doWork();

            return 0;
        }
    }

    // [Lua] startTimedEvent(event [, params])
    private class StartTimedEvent implements NamedJavaFunction {
        /**
         * Gets the name of the Lua function as it would appear in the Lua script.
         *
         * @return Returns the name of the custom Lua function.
         */
        @Override
        public String getName() {
            return "startTimedEvent";
        }

        /**
         * This method is called when the Lua function is called.
         * <p>
         * Warning! This method is not called on the main UI thread.
         *
         * @param luaState Reference to the Lua state.
         *                 Needed to retrieve the Lua function's parameters and to return values back to Lua.
         * @return Returns the number of values to be returned by the Lua function.
         */
        @Override
        public int invoke(LuaState luaState) {
            functionSignature = "flurry.startTimedEvent(event, options)";
            LogEventWorker worker = new LogEventWorker(luaState, true, false); // luaState, isTimed, shouldEndTimedEvent
            worker.doWork();

            return 0;
        }
    }

    // [Lua] endTimedEvent(event [, params])
    private class EndTimedEvent implements NamedJavaFunction {
        /**
         * Gets the name of the Lua function as it would appear in the Lua script.
         *
         * @return Returns the name of the custom Lua function.
         */
        @Override
        public String getName() {
            return "endTimedEvent";
        }

        /**
         * This method is called when the Lua function is called.
         * <p>
         * Warning! This method is not called on the main UI thread.
         *
         * @param luaState Reference to the Lua state.
         *                 Needed to retrieve the Lua function's parameters and to return values back to Lua.
         * @return Returns the number of values to be returned by the Lua function.
         */
        @Override
        public int invoke(LuaState luaState) {
            functionSignature = "flurry.endTimedEvent(event, options)";
            LogEventWorker worker = new LogEventWorker(luaState, true, true); // luaState, isTimed, shouldEndTimedEvent
            worker.doWork();

            return 0;
        }
    }

    // [Lua] openPrivacyDashboard( )
    private class OpenPrivacyDashboard implements NamedJavaFunction {
        /**
         * Gets the name of the Lua function as it would appear in the Lua script.
         *
         * @return Returns the name of the custom Lua function.
         */
        @Override
        public String getName() {
            return "openPrivacyDashboard";
        }

        /**
         * This method is called when the Lua function is called.
         * <p>
         * Warning! This method is not called on the main UI thread.
         *
         * @param luaState Reference to the Lua state.
         *                 Needed to retrieve the Lua function's parameters and to return values back to Lua.
         * @return Returns the number of values to be returned by the Lua function.
         */
        @Override
        public int invoke(LuaState luaState) {
            functionSignature = "flurry.openPrivacyDashboard( )";


            final FlurryPrivacySession.Callback callback = new FlurryPrivacySession.Callback() {
                @Override
                public void success() {
                    Log.d("FLURRYTAG", "Privacy Dashboard opened successfully");
                }

                @Override
                public void failure() {
                    Log.d("FLURRYTAG", "Opening Privacy Dashboard failed");
                }
            };

            final FlurryPrivacySession.Request request = new FlurryPrivacySession.Request(CoronaEnvironment.getApplicationContext(), callback);
            FlurryAgent.openPrivacyDashboard(request);

            //FlurryAgent.req

            return 0;
        }
    }

    // -------------------------------------------------------------------------
    // Flurry delegate class
    // -------------------------------------------------------------------------
    private class CoronaFlurryDelegate implements FlurryAgentListener {
        // Called when session has been started
        @Override
        public void onSessionStarted() {
            // NOP
            // We can't use this due to timing issues. (as explained in 'init' above)
        }
    }
}

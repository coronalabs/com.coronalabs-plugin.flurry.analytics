//
//  FlurryPlugin.h
//  Flurry Plugin
//
//  Copyright (c) 2016 Corona Labs Inc. All rights reserved.
//

#ifndef FlurryPlugin_H
#define FlurryPlugin_H

#import "CoronaLua.h"
#import "CoronaMacros.h"

// This corresponds to the name of the library, e.g. [Lua] require "plugin.library"
// where the '.' is replaced with '_'
CORONA_EXPORT int luaopen_plugin_flurry_analytics( lua_State *L );

#endif // FlurryPlugin_H

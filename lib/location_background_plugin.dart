// Copyright 2018 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

// Required for PluginUtilities.
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Types of location activities for iOS.
/// 
/// See https://developer.apple.com/documentation/corelocation/clactivitytype
enum LocationActivityType {
  other,
  automotiveNavigation,
  fitness,
  otherNavigation,
}

/// Types of accuracy modes for iOS.
///
/// See https://developer.apple.com/documentation/corelocation/cllocationaccuracy
enum LocationAccuracy {
  bestForNavigation,
  best,
  nearestTenMeters,
  hundredMeters,
  kilometer,
  threeKilometers,
}

/// A representation of a location update.
class Location {
  DateTime get time =>
      new DateTime.fromMillisecondsSinceEpoch((_time * 1000).round(),
          isUtc: true);

  final double _time;
  final double latitude;
  final double longitude;
  final double altitude;
  final double speed;

  Location(
      this._time, this.latitude, this.longitude, this.altitude, this.speed);

  factory Location.fromJson(String jsonLocation) {
    Map<String, dynamic> location = json.decode(jsonLocation);
    return new Location(location['time'], location['latitude'],
        location['longitude'], location['altitude'], location['speed']);
  }

  @override
  String toString() =>
      '[$time] ($latitude, $longitude) altitude: $altitude m/s: $speed';

  String toJson() {
    Map<String, double> location = {
      'time': _time,
      'latitude': latitude,
      'longitude': longitude,
      'altitude': altitude,
      'speed': speed,
    };
    return json.encode(location);
  }
}

// When we start the background service isolate, we only ever enter it once.
// To communicate between the native plugin and this entrypoint, we'll use
// MethodChannels to open a persistent communication channel to trigger
// callbacks.
_backgroundCallbackDispatcher() {
  const String kOnLocationEvent = 'onLocationEvent';
  const MethodChannel _channel = const MethodChannel(
      'plugins.flutter.io/ios_background_location_callback');

  final Map<String, Function> _callbackCache = new Map<String, Function>();

  // Setup Flutter state needed for MethodChannels.
  WidgetsFlutterBinding.ensureInitialized();

  // This is where the magic happens and we handle background events from the
  // native portion of the plugin. Here we massage the location data into a
  // `Location` object which we then pass to the provided callback.
  _channel.setMethodCallHandler((MethodCall call) async {
    final args = call.arguments;

    // args[0].runtimeType == List<dynamic>
    // pair[0] = closure name
    // pair[1] = closure library path
    final pair = args[0].cast<String>();
    final cacheKey = pair.join('@');

    Function closure;
    // To avoid making repeated lookups of our callback, store the resulting
    // closure in a cache based on the closure name and its library path.
    if (_callbackCache.containsKey(cacheKey)) {
      closure = _callbackCache[cacheKey];
    } else {
      // PluginUtilities.getClosureByName performs a lookup based on the name
      // of a closure as well as its library Uri.
      closure = PluginUtilities.getClosureByName(
          name: pair[0], libraryUri: Uri.parse(pair[1]));
      _callbackCache[cacheKey] = closure;
    }
    assert(
        closure != null, 'Could not find closure: ${pair[0]} in ${pair[1]}.');

    if (call.method == kOnLocationEvent) {
      final location =
          new Location(args[1], args[2], args[3], args[4], args[5]);
      closure(location);
    } else {
      assert(false, "No handler defined for method type: '${call.method}'");
    }
  });
}

class LocationBackgroundPlugin {
  // The method channel we'll use to communicate with the native portion of our
  // plugin.
  static const MethodChannel _channel =
      const MethodChannel('plugins.flutter.io/ios_background_location');

  static const String _kCancelLocationUpdates = 'cancelLocationUpdates';
  static const String _kMonitorLocationChanges = 'monitorLocationChanges';
  static const String _kStartHeadlessService = 'startHeadlessService';

  bool pauseLocationUpdatesAutomatically;
  bool showsBackgroundLocationIndicator;
  int distanceFilter;
  LocationAccuracy desiredAccuracy;
  LocationActivityType activityType;

  LocationBackgroundPlugin(
      {this.pauseLocationUpdatesAutomatically = true,
      this.showsBackgroundLocationIndicator = false,
      this.distanceFilter = 0,
      this.desiredAccuracy = LocationAccuracy.best,
      this.activityType = LocationActivityType.other}) {
    // Start the headless location service. The parameters here are the name of
    // the entrypoint for our callback and the path to the library that calls
    print("Starting LocationBackgroundPlugin service");
    _channel.invokeMethod(_kStartHeadlessService, <dynamic>[
      PluginUtilities.getNameOfFunction(_backgroundCallbackDispatcher),
      PluginUtilities.getPathForFunctionLibrary(_backgroundCallbackDispatcher)
    ]);
  }

  /// Start getting location updates through `callback`.
  /// 
  /// `callback` is invoked on a background isolate and will not have direct
  /// access to the state held by the main isolate (or any other isolate).
  Future<bool> monitorLocationChanges(
      void Function(Location location) callback) {
    if (callback == null) {
      throw ArgumentError.notNull('callback');
    }
    return _channel.invokeMethod(_kMonitorLocationChanges, <dynamic>[
      PluginUtilities.getNameOfFunction(callback),
      PluginUtilities.getPathForFunctionLibrary(callback),
      pauseLocationUpdatesAutomatically,
      showsBackgroundLocationIndicator,
      distanceFilter,
      desiredAccuracy.index,
      activityType.index
    ]).then<bool>((dynamic result) => result);
  }

  /// Stop all location updates.
  Future<void> cancelLocationUpdates() =>
      _channel.invokeMethod(_kCancelLocationUpdates);
}

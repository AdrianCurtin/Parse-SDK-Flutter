part of '../../parse_server_sdk.dart';

class ParseInstallation extends ParseObject {
  /// Creates an instance of ParseInstallation
  ParseInstallation({bool? debug, ParseClient? client, bool? autoSendSessionId})
    : super(
        keyClassInstallation,
        client: client,
        autoSendSessionId: autoSendSessionId,
        debug: debug,
      );

  ParseInstallation.forQuery() : super(keyClassUser);

  static final List<String> readOnlyKeys = <String>[
    keyDeviceToken,
    keyDeviceType,
    keyInstallationId,
    keyAppName,
    keyAppVersion,
    keyAppIdentifier,
    keyParseVersion,
  ];
  static String? _currentInstallationId;
  static bool _timeZonesInitialized = false;

  /// Single source of truth for "is this installationId usable as a header
  /// value and a request body field". Empty strings and whitespace-only
  /// strings are rejected; a stale store containing either should fall
  /// through to UUID regeneration rather than be reused.
  static bool _isUsableInstallationId(Object? value) {
    return value is String && value.trim().isNotEmpty;
  }

  //Getters/setters
  Map<String, dynamic> get acl => super.get<Map<String, dynamic>>(
    keyVarAcl,
    defaultValue: <String, dynamic>{},
  )!;

  set acl(Map<String, dynamic> acl) =>
      set<Map<String, dynamic>>(keyVarAcl, acl);

  String? get deviceToken => super.get<String>(keyDeviceToken);

  set deviceToken(String? deviceToken) =>
      set<String?>(keyDeviceToken, deviceToken);

  String? get deviceType => super.get<String>(keyDeviceType);

  String? get installationId => super.get<String>(keyInstallationId);

  set _installationId(String? installationId) =>
      set<String?>(keyInstallationId, installationId);

  String? get appName => super.get<String>(keyAppName);

  String? get appVersion => super.get<String>(keyAppVersion);

  String? get appIdentifier => super.get<String>(keyAppIdentifier);

  String? get parseVersion => super.get<String>(keyParseVersion);

  static Future<bool> isCurrent(ParseInstallation installation) async {
    // Treat an empty-string cache as missing. Older SDK builds could write
    // `installationId: ""` to the local store when the timezone resolver
    // failed; reading that value back populates the cache with "", and `??=`
    // would happily leave the empty string in place — poisoning every
    // subsequent header and POST body.
    if (!_isUsableInstallationId(_currentInstallationId)) {
      final String? stored = (await _getFromLocalStore())?.installationId;
      _currentInstallationId =
          _isUsableInstallationId(stored) ? stored : null;
    }
    return _currentInstallationId != null &&
        installation.installationId == _currentInstallationId;
  }

  /// Gets the current installation from storage
  static Future<ParseInstallation> currentInstallation() async {
    return (await _getFromLocalStore()) ?? (await _createInstallation());
  }

  /// Returns the current installation's UUID. Hot path for
  /// `ParseClient.buildHeaders`, which runs on every HTTP request.
  ///
  /// The first call reads `keyInstallationId` directly from the JSON stored
  /// at [keyParseStoreInstallation] — without going through `fromJson` and
  /// constructing a full `ParseInstallation` with its dirty-tracking maps.
  /// Subsequent calls return the value from the static cache in
  /// [_currentInstallationId]. The install ID is immutable for the lifetime
  /// of the app on a given device, so the cache never needs invalidation.
  static Future<String?> currentInstallationId() async {
    if (_isUsableInstallationId(_currentInstallationId)) {
      return _currentInstallationId;
    }
    final String? stored = await _readInstallationIdFromStore();
    if (stored != null) {
      _currentInstallationId = stored;
      return _currentInstallationId;
    }
    // Bootstrap. `_createInstallation` sets `_currentInstallationId` via `??=`
    // *before* it attempts persistence; if persistence throws we clear the
    // cache so the next call retries the write. Matches the pre-cache
    // behaviour of `currentInstallation()`, which would re-enter
    // `_createInstallation` on every call until storage succeeded.
    try {
      await _createInstallation();
    } catch (_) {
      _currentInstallationId = null;
      rethrow;
    }
    return _currentInstallationId;
  }

  /// Clears the cached installation UUID so the next call to
  /// [currentInstallationId] re-reads from the local store. Intended for tests
  /// that wipe storage between cases, and for apps that re-initialize Parse or
  /// clear the core store mid-session.
  @visibleForTesting
  static void debugResetInstallationIdCache() {
    _currentInstallationId = null;
  }

  /// Reads just the installation UUID out of the locally-stored JSON map,
  /// avoiding a full `ParseInstallation()..fromJson(...)` round-trip when the
  /// caller only needs the ID (see [currentInstallationId]).
  static Future<String?> _readInstallationIdFromStore() async {
    final String? installationJson = await ParseCoreData()
        .getStore()
        .getString(keyParseStoreInstallation);
    if (installationJson == null) return null;
    final dynamic decoded = json.decode(installationJson);
    if (decoded is! Map<String, dynamic>) return null;
    final dynamic id = decoded[keyInstallationId];
    return _isUsableInstallationId(id) ? id as String : null;
  }

  /// Updates the installation with current device data
  Future<void> _updateInstallation() async {
    //Device type
    if (parseIsWeb) {
      set<String>(keyDeviceType, 'web');
    } else if (Platform.isAndroid) {
      set<String>(keyDeviceType, 'android');
    } else if (Platform.isIOS) {
      set<String>(keyDeviceType, 'ios');
    } else if (Platform.isLinux) {
      set<String>(keyDeviceType, 'Linux');
    } else if (Platform.isMacOS) {
      set<String>(keyDeviceType, 'MacOS');
    } else if (Platform.isWindows) {
      set<String>(keyDeviceType, 'Windows');
    }

    //Locale
    set<String?>(keyLocaleIdentifier, ParseCoreData().locale);

    //Timezone — don't overwrite a value the caller already set. The pure-Dart
    //offset-match here picks the first IANA zone with the local offset, which
    //is alphabetical (e.g. "America/Anguilla" for UTC-4 instead of
    //"America/New_York"). Apps that need a real IANA name (via a Flutter
    //plugin like flutter_timezone, or a Kotlin/Swift channel) should set
    //`timeZone` on the installation before calling save(); the SDK will only
    //fill it in when nothing is set.
    //
    //First-launch caveat: _createInstallation() runs this method and then
    //persists the full installation JSON to the local store before any
    //caller code runs. That means the offset-matched fallback IS written to
    //disk on first launch. If the app crashes before the caller's
    //set+save() runs, the next launch reads the fallback from storage, the
    //gate sees it as "existing", and the SDK won't auto-correct. The
    //caller's set+save self-heals as soon as it runs. Apps that resolve a
    //real IANA name should do so early in startup.
    final String? existingTimeZone = super.get<String>(keyTimeZone);
    if (existingTimeZone == null || existingTimeZone.isEmpty) {
      set<String>(keyTimeZone, _getNameLocalTimeZone());
    }

    //App info
    set<String?>(keyAppName, ParseCoreData().appName);
    set<String?>(keyAppVersion, ParseCoreData().appVersion);
    set<String?>(keyAppIdentifier, ParseCoreData().appPackageName);
    set<String>(keyParseVersion, keySdkVersion);

    // Make sure installationId lands in `_unsavedChanges` so `_create()`'s
    // `toJson(forApiRQ: true)` body actually carries it. `_getFromLocalStore`
    // uses `fromJson(addInUnSave: false)`, which only populates `_objectData`.
    // If the process died between local persist and the first server POST,
    // the next launch would otherwise create a server row with no
    // installationId, breaking any later server-side lookups that match by
    // the UUID the device sends in the `X-Parse-Installation-Id` header.
    if (objectId == null) {
      final String? currentId = installationId;
      if (_isUsableInstallationId(currentId)) {
        set<String>(keyInstallationId, currentId!);
      }
    }
  }

  String _getNameLocalTimeZone() {
    // The timezone database is large; initialize it at most once per process.
    if (!_timeZonesInitialized) {
      tz.initializeTimeZones();
      _timeZonesInitialized = true;
    }

    // Capture once to avoid a DST-transition race between the two reads.
    final DateTime now = DateTime.now();

    // Prefer the OS-reported zone name when it's a valid IANA location
    // (e.g. "America/New_York" on macOS/Linux/iOS/Android). Avoids the
    // ambiguity of matching by offset, where many zones share an offset.
    final String systemName = now.timeZoneName;
    if (tz.timeZoneDatabase.locations.containsKey(systemName)) {
      return systemName;
    }

    // Fall back to a location whose *current* zone matches the local
    // offset. The previous implementation scanned every historical zone
    // (LMT, pre-DST, etc.) and compared a Duration against an int offset,
    // which on timezone <0.11.0 is always false and produced "".
    final int localOffsetMs = now.timeZoneOffset.inMilliseconds;
    for (final location in tz.timeZoneDatabase.locations.values) {
      if (_zoneOffsetMs(location.currentTimeZone.offset) == localOffsetMs) {
        return location.name;
      }
    }

    // Last resort: return whatever the OS gave us rather than "".
    // Note: on Windows/Web this may be a non-IANA name (e.g.
    // "Pacific Standard Time" or "EDT"), but it's still better than "".
    return systemName;
  }

  // The `timezone` package returns `TimeZone.offset` as `int` (milliseconds)
  // on <0.11.0 and as `Duration` on >=0.11.0. Normalize to milliseconds so
  // the same comparison works across the full supported version range.
  static int _zoneOffsetMs(dynamic offset) {
    if (offset is Duration) return offset.inMilliseconds;
    return offset as int;
  }

  @override
  Future<ParseResponse> create({
    bool allowCustomObjectId = false,
    dynamic context,
  }) async {
    final bool isCurrent = await ParseInstallation.isCurrent(this);
    if (isCurrent) {
      await _updateInstallation();
    }

    final ParseResponse parseResponse = await _create(
      allowCustomObjectId: allowCustomObjectId,
    );
    if (parseResponse.success && isCurrent) {
      clearUnsavedChanges();
      await saveInStorage(keyParseStoreInstallation);
    }
    return parseResponse;
  }

  /// Saves the current installation
  @override
  Future<ParseResponse> save({dynamic context}) async {
    final bool isCurrent = await ParseInstallation.isCurrent(this);
    if (isCurrent) {
      await _updateInstallation();
    }
    //ParseResponse parseResponse = await super.save();
    final ParseResponse parseResponse = await _save();
    if (parseResponse.success && isCurrent) {
      clearUnsavedChanges();
      await saveInStorage(keyParseStoreInstallation);
    }
    return parseResponse;
  }

  /// Gets the locally stored installation
  ///
  /// Returns null if the stored JSON is missing or unusable (no
  /// installationId, or installationId is the empty string). Callers fall
  /// through to [_createInstallation], which generates a fresh UUID rather
  /// than reusing the poisoned value. Centralizing the validity check here
  /// keeps corrupted local state from leaking into server requests.
  static Future<ParseInstallation?> _getFromLocalStore() async {
    final CoreStore coreStore = ParseCoreData().getStore();

    final String? installationJson = await coreStore.getString(
      keyParseStoreInstallation,
    );

    if (installationJson != null) {
      // json.decode returns dynamic; defensively type-check rather than
      // letting an unexpected list/scalar throw a TypeError on the implicit
      // cast to Map<String, dynamic>?.
      final dynamic decoded = json.decode(installationJson);
      if (decoded is Map<String, dynamic>) {
        if (!_isUsableInstallationId(decoded[keyInstallationId])) {
          // A store missing or carrying an unusable installationId would
          // otherwise propagate the bad value into every outgoing request.
          // Drop it and let the caller regenerate. Log so operators can
          // correlate "device suddenly stopped receiving push" reports
          // with installation rotation.
          if (ParseCoreData().debug) {
            print(
              'ParseInstallation: discarding stored installation with '
              'missing/empty installationId; a new UUID will be minted.',
            );
          }
          return null;
        }
        return ParseInstallation()..fromJson(decoded);
      }
    }

    return null;
  }

  /// Creates a installation for current device
  /// Assumes that this is called because there is no previous installation
  /// so it creates and sets the static current installation UUID
  static Future<ParseInstallation> _createInstallation() async {
    // Explicit null-or-empty check. `??=` would leave a cached empty string
    // in place — that was the bug that wrote `installationId: ""` to the
    // server and produced rows the device's later UUID could never match.
    if (!_isUsableInstallationId(_currentInstallationId)) {
      _currentInstallationId = const Uuid().v4();
    }

    final ParseInstallation installation = ParseInstallation();
    installation._installationId = _currentInstallationId;
    await installation._updateInstallation();
    await ParseCoreData().getStore().setString(
      keyParseStoreInstallation,
      json.encode(installation.toJson(full: true)),
    );
    return installation;
  }

  /// Creates a new object and saves it online
  Future<ParseResponse> _create({bool allowCustomObjectId = false}) async {
    try {
      final String uri =
          '${ParseCoreData().serverUrl}$keyEndPointInstallations';
      final String body = json.encode(
        toJson(forApiRQ: true, allowCustomObjectId: allowCustomObjectId),
      );
      final Map<String, String> headers = <String, String>{
        keyHeaderContentType: keyHeaderContentTypeJson,
      };
      if (_debug) {
        logRequest(
          ParseCoreData().appName,
          parseClassName,
          ParseApiRQ.create.toString(),
          uri,
          body,
        );
      }

      final ParseNetworkResponse result = await _client.post(
        uri,
        data: body,
        options: ParseNetworkOptions(headers: headers),
      );

      //Set the objectId on the object after it is created.
      //This allows you to perform operations on the object after creation
      if (result.statusCode == 201) {
        final Map<String, dynamic> map = json.decode(result.data);
        objectId = map['objectId'].toString();
      }

      return handleResponse<ParseInstallation>(
        this,
        result,
        ParseApiRQ.create,
        _debug,
        parseClassName,
      );
    } on Exception catch (e) {
      return handleException(e, ParseApiRQ.create, _debug, parseClassName);
    }
  }

  /// Saves the current object online
  Future<ParseResponse> _save() async {
    if (objectId == null) {
      return create();
    } else {
      try {
        final String uri =
            '${ParseCoreData().serverUrl}$keyEndPointInstallations/$objectId';
        final String body = json.encode(toJson(forApiRQ: true));
        if (_debug) {
          logRequest(
            ParseCoreData().appName,
            parseClassName,
            ParseApiRQ.save.toString(),
            uri,
            body,
          );
        }
        final ParseNetworkResponse result = await _client.put(uri, data: body);
        return handleResponse<ParseInstallation>(
          this,
          result,
          ParseApiRQ.save,
          _debug,
          parseClassName,
        );
      } on Exception catch (e) {
        return handleException(e, ParseApiRQ.save, _debug, parseClassName);
      }
    }
  }

  ///Subscribes the device to a channel of push notifications.
  Future<void> subscribeToChannel(String value) async {
    final List<dynamic> channel = <String>[value];
    setAddAllUnique('channels', channel);
    await save();
  }

  ///Unsubscribes the device to a channel of push notifications.
  Future<void> unsubscribeFromChannel(String value) async {
    final List<dynamic> channel = <String>[value];
    setRemove('channels', channel);
    await save();
  }

  ///Returns a `List<String>` containing all the channel names this device is subscribed to.
  Future<List<dynamic>> getSubscribedChannels() async {
    print('getSubscribedChannels');
    final ParseResponse apiResponse = await ParseObject(
      keyClassInstallation,
    ).getObject(objectId!);

    if (apiResponse.success) {
      final ParseObject installation = apiResponse.result;
      return Future<List<dynamic>>.value(
        installation.get<List<dynamic>>('channels', defaultValue: <dynamic>[]),
      );
    } else {
      return <String>[];
    }
  }
}

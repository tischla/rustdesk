// Client-side rendezvous server profiles.
//
// Profiles only affect OUTGOING connections of this client. The service keeps using the
// server configured under Settings > Network > ID/Relay Server.
// Profiles are stored as JSON in the local option `server-profiles`; the profile used for
// connections without explicit `@profile` suffix is stored in `default-server-profile`.
// Resolution `<id>@<profile>` -> `<id>@<host>?key=<key>` happens in Rust
// (src/server_profiles.rs), so CLI / URI connects behave identically.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../common.dart';
import '../models/platform_model.dart';

const String kOptionServerProfiles = 'server-profiles';
const String kOptionDefaultServerProfile = 'default-server-profile';

final RegExp _nameRegExp = RegExp(r'^[A-Za-z0-9_-]{1,32}$');
final RegExp _invalidHostKeyChars = RegExp(r'[@?&\s]');

class ServerProfile {
  String name;
  String host;
  String key;
  String description;

  ServerProfile(
      {required this.name,
      required this.host,
      this.key = '',
      this.description = ''});

  factory ServerProfile.fromJson(Map<String, dynamic> json) => ServerProfile(
        name: (json['name'] ?? '').toString(),
        host: (json['host'] ?? '').toString(),
        key: (json['key'] ?? '').toString(),
        description: (json['description'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'host': host,
        'key': key,
        'description': description,
      };

  String get label => description.isEmpty ? name : '$name – $description';
}

/// Reactive list, shared by the connection page selector and the settings dialog.
final RxList<ServerProfile> serverProfiles = <ServerProfile>[].obs;
final RxString defaultServerProfile = ''.obs;
bool _loaded = false;

void loadServerProfiles({bool force = false}) {
  if (_loaded && !force) return;
  _loaded = true;
  final list = <ServerProfile>[];
  try {
    final raw = bind.mainGetLocalOption(key: kOptionServerProfiles);
    if (raw.isNotEmpty) {
      for (final e in jsonDecode(raw) as List) {
        list.add(ServerProfile.fromJson(e as Map<String, dynamic>));
      }
    }
  } catch (e) {
    debugPrint('Invalid $kOptionServerProfiles: $e');
  }
  serverProfiles.assignAll(list);
  var def = bind.mainGetLocalOption(key: kOptionDefaultServerProfile);
  if (def.isNotEmpty && findServerProfile(def) == null) def = '';
  defaultServerProfile.value = def;
}

Future<void> _saveServerProfiles() async {
  await bind.mainSetLocalOption(
      key: kOptionServerProfiles,
      value: jsonEncode(serverProfiles.map((e) => e.toJson()).toList()));
}

Future<void> setDefaultServerProfile(String name) async {
  defaultServerProfile.value = name;
  await bind.mainSetLocalOption(key: kOptionDefaultServerProfile, value: name);
}

ServerProfile? findServerProfile(String name) {
  final n = name.toLowerCase();
  return serverProfiles.firstWhereOrNull((p) => p.name.toLowerCase() == n);
}

/// Append the selected profile to a plain id, so the session window, reconnects and the
/// recent list are bound to that profile even if the default is changed afterwards.
/// Ids that already carry `@...` (explicit profile or server) are left unchanged.
String applyServerProfile(String id) {
  if (isWeb || id.isEmpty || id.contains('@')) return id;
  // Read fresh values: secondary windows run in their own isolate and may hold a stale copy.
  loadServerProfiles(force: true);
  final name = defaultServerProfile.value;
  if (name.isEmpty || findServerProfile(name) == null) return id;
  return '$id@$name';
}

String? _validate(ServerProfile p, {String? originalName}) {
  if (!_nameRegExp.hasMatch(p.name)) {
    return translate('server-profile-name-tip');
  }
  final existing = findServerProfile(p.name);
  if (existing != null &&
      existing.name.toLowerCase() != (originalName ?? '').toLowerCase()) {
    return translate('server-profile-name-exists');
  }
  if (p.host.isEmpty || _invalidHostKeyChars.hasMatch(p.host)) {
    return translate('Invalid ID Server');
  }
  if (_invalidHostKeyChars.hasMatch(p.key)) {
    return translate('Invalid Key');
  }
  return null;
}

/// Dropdown for the connection page: which server outgoing connections use.
class ServerProfileSelector extends StatelessWidget {
  const ServerProfileSelector({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    loadServerProfiles();
    return Obx(() {
      if (serverProfiles.isEmpty) return const Offstage();
      final items = <DropdownMenuItem<String>>[
        DropdownMenuItem(
          value: '',
          child: Text(translate('server-profile-service'),
              overflow: TextOverflow.ellipsis),
        ),
        ...serverProfiles.map((p) => DropdownMenuItem(
              value: p.name,
              child: Tooltip(
                message: p.host,
                waitDuration: const Duration(milliseconds: 600),
                child: Text(p.label, overflow: TextOverflow.ellipsis),
              ),
            )),
      ];
      return Tooltip(
        message: translate('server-profile-selector-tip'),
        waitDuration: const Duration(milliseconds: 1000),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: defaultServerProfile.value,
              isDense: true,
              isExpanded: true,
              icon: const Icon(Icons.dns_outlined, size: 14),
              style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).textTheme.bodyMedium?.color),
              items: items,
              onChanged: (v) => setDefaultServerProfile(v ?? ''),
            ),
          ),
        ),
      );
    });
  }
}

/// List/add/edit/delete dialog, opened from Settings > Network.
void showServerProfilesDialog(OverlayDialogManager dialogManager) {
  loadServerProfiles(force: true);
  dialogManager.show((setState, close, context) {
    Widget row(ServerProfile p) => ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            defaultServerProfile.value == p.name
                ? Icons.radio_button_checked
                : Icons.dns_outlined,
            size: 18,
          ),
          title: Text(p.label),
          subtitle: Text(
              '${p.host}${p.key.isEmpty ? '' : '  •  ${translate('Key')}: ${p.key.length > 8 ? '${p.key.substring(0, 8)}…' : p.key}'}'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: translate('Edit'),
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: () => _showEditDialog(dialogManager, p,
                  onSaved: () => setState(() {})),
            ),
            IconButton(
              tooltip: translate('Delete'),
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () async {
                serverProfiles.remove(p);
                await _saveServerProfiles();
                if (defaultServerProfile.value == p.name) {
                  await setDefaultServerProfile('');
                }
                setState(() {});
              },
            ),
          ]),
        );

    return CustomAlertDialog(
      title: Text(translate('Server profiles')),
      contentBoxConstraints: const BoxConstraints(minWidth: 480, maxWidth: 560),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(translate('server-profiles-tip'),
              style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          if (serverProfiles.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(translate('server-profiles-empty')),
            ),
          ...serverProfiles.map(row),
        ],
      ),
      actions: [
        dialogButton('Add', isOutline: true, onPressed: () {
          _showEditDialog(dialogManager, null, onSaved: () => setState(() {}));
        }),
        dialogButton('Close', onPressed: close),
      ],
      onCancel: close,
    );
  });
}

void _showEditDialog(OverlayDialogManager dialogManager, ServerProfile? orig,
    {required VoidCallback onSaved}) {
  final nameCtrl = TextEditingController(text: orig?.name ?? '');
  final hostCtrl = TextEditingController(text: orig?.host ?? '');
  final keyCtrl = TextEditingController(text: orig?.key ?? '');
  final descCtrl = TextEditingController(text: orig?.description ?? '');
  String? error;

  dialogManager.show((setState, close, context) {
    Future<void> submit() async {
      final p = ServerProfile(
        name: nameCtrl.text.trim(),
        host: hostCtrl.text.trim(),
        key: keyCtrl.text.trim(),
        description: descCtrl.text.trim(),
      );
      final err = _validate(p, originalName: orig?.name);
      if (err != null) {
        setState(() => error = err);
        return;
      }
      if (orig != null) {
        final idx = serverProfiles.indexOf(orig);
        serverProfiles[idx] = p;
        if (defaultServerProfile.value == orig.name && orig.name != p.name) {
          await setDefaultServerProfile(p.name);
        }
      } else {
        serverProfiles.add(p);
      }
      await _saveServerProfiles();
      onSaved();
      close();
    }

    Widget field(String label, TextEditingController c, {String? hint}) =>
        TextField(
          controller: c,
          decoration: InputDecoration(
            labelText: translate(label),
            hintText: hint,
            isDense: true,
          ),
          onSubmitted: (_) => submit(),
        ).marginOnly(bottom: 8);

    return CustomAlertDialog(
      title: Text(translate(orig == null ? 'Add' : 'Edit')),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        field('Name', nameCtrl, hint: 'pwe'),
        field('ID Server', hostCtrl, hint: 'rd.example.com[:21116]'),
        field('Key', keyCtrl),
        field('Description', descCtrl),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
      ]),
      actions: [
        dialogButton('Cancel', isOutline: true, onPressed: close),
        dialogButton('OK', onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

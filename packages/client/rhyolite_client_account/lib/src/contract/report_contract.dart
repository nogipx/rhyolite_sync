// ignore_for_file: uri_has_not_been_generated

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

part 'report_contract.g.dart';

/// Largest archive the server will take, before base64.
///
/// Set to be hard to reach rather than to be a typical size, because the cap
/// selects against exactly the reports worth having: the biggest archive comes
/// from the loudest logs — a first sync of a huge vault, a livelock, a
/// reconnect loop — which is the case the whole feature exists for. A limit
/// that fires there would turn the best report into "attach it by hand".
///
/// The upper bound is not a guess. The plugin caps what it retains on disk at
/// roughly 26 MB (segments plus the problems file) and that ceiling is
/// enforced, so an archive cannot exceed it however badly compression does.
/// Log text gzips by about tenfold, putting a real archive at two or three
/// megabytes; reaching sixteen would need compression to fail almost
/// completely. So this should never fire, which is the point.
///
/// Storage is what bounds it from the other side. One row per account, and the
/// row holds base64, so the worst case costs a third more than the number
/// here: ~21 MB per account that ever submits. Against a 10 GiB volume shared
/// with everything else this server keeps, that is affordable for the handful
/// of accounts that will ever press the button, and it stays bounded because
/// a resubmission replaces the row rather than adding one.
///
/// Nothing external forces a limit: no request-body cap in the account server
/// or the ingress, and Postgres TOASTs a field this size without noticing.
/// What is left is memory — the archive, its base64 and the request body are
/// live at once, on a phone. If a measured archive ever approaches this, the
/// answer is a `clientStream` upload (rpc_dart has it; nothing here uses it
/// yet), which keeps memory flat and removes the notion of a limit rather
/// than raising it again.
///
/// A vault that does exceed this keeps the local archive and attaches it by
/// hand. Checked on BOTH sides: on the client so a doomed upload never starts
/// over a phone connection, on the server because a client limit is a request.
const kMaxReportArchiveBytes = 16 * 1024 * 1024;

// --- DTOs ---

class SubmitReportRequest implements IRpcSerializable {
  const SubmitReportRequest({
    required this.archiveBase64,
    required this.description,
    required this.pluginVersion,
    required this.platform,
  });

  /// The gzip archive, base64 encoded. Base64 because the payload is JSON;
  /// it costs a third in size, which the cap above already accounts for.
  final String archiveBase64;

  /// What the user typed about the problem. May be empty — a report with no
  /// description still carries the logs.
  final String description;

  /// Plugin version and platform, duplicated out of the archive so a report
  /// can be triaged from the list without opening it.
  final String pluginVersion;
  final String platform;

  factory SubmitReportRequest.fromJson(Map<String, dynamic> json) =>
      SubmitReportRequest(
        archiveBase64: json['archive_base64'] as String,
        description: json['description'] as String? ?? '',
        pluginVersion: json['plugin_version'] as String? ?? '',
        platform: json['platform'] as String? ?? '',
      );

  @override
  Map<String, dynamic> toJson() => {
        'archive_base64': archiveBase64,
        'description': description,
        'plugin_version': pluginVersion,
        'platform': platform,
      };
}

class SubmitReportResponse implements IRpcSerializable {
  const SubmitReportResponse({required this.reportId});

  /// Short, readable, and quotable: the user says it out loud in a chat, so it
  /// has to survive being typed by hand.
  final String reportId;

  factory SubmitReportResponse.fromJson(Map<String, dynamic> json) =>
      SubmitReportResponse(reportId: json['report_id'] as String);

  @override
  Map<String, dynamic> toJson() => {'report_id': reportId};
}

// --- Contract ---

/// Diagnostic reports, uploaded by a user who is asking for help.
///
/// One row per account, overwritten. That is the whole retention policy: the
/// newest report is the one being discussed, and an account cannot accumulate
/// storage by pressing the button. It also means a previous report is gone
/// once a new one arrives — acceptable because a report is reproducible on
/// demand, unlike the data it describes.
@RpcService(name: 'RhyoliteReports', transferMode: RpcDataTransferMode.codec)
abstract class IReportContract {
  /// Uploads the archive for the CURRENTLY AUTHENTICATED user.
  ///
  /// Requires auth: the account is both the identity and the storage key, and
  /// an unauthenticated version of this would be an open write endpoint. The
  /// cost is that someone whose sign-in is broken cannot use it — they still
  /// have the local archive to attach by hand, which is the path that has
  /// always worked.
  @RpcMethod.unary(name: 'submitReport')
  Future<SubmitReportResponse> submitReport(
    SubmitReportRequest request, {
    RpcContext? context,
  });
}

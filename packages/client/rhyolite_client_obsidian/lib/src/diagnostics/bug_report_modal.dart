// ignore_for_file: deprecated_member_use
import 'dart:js_interop';
import 'dart:js_util' as jsu;
import 'dart:typed_data';

import 'package:obsidian_dart/obsidian_dart.dart';

import 'package:rhyolite_client_account/rhyolite_client_account.dart'
    show kMaxReportArchiveBytes;
import 'package:rpc_dart/rpc_dart.dart' show LogScope;

import '../i18n/i18n.dart';
import 'bug_report.dart';
import 'zip_writer.dart';

/// Collects a bug report, writes it into the vault, and points the user at
/// support.
///
/// The archive is written into the vault FIRST and uploaded second, so the
/// file is the outcome that can always be promised: a failed upload still
/// leaves something to attach by hand, and on a phone that is the only
/// delivery that has ever worked. Where it goes is stated on the first screen,
/// before anything is collected — a report that turns out to have been sent is
/// not a surprise this product gets to spring.
///
/// Note names never leave in readable form: they are pseudonymised on the way
/// into the log file, not scrubbed out of it afterwards.
Future<void> showBugReportModal(
  PluginHandle plugin, {
  required Future<(BugReport, List<(String, String)>)> Function(
    String description,
  )
  buildReport,
  required void Function(String url) openUrl,
  required String supportUrl,

  /// Uploads the archive and returns the id the user can quote. Null when
  /// there is nobody to upload to — a self-hosted server has no account
  /// service — in which case the archive stays a file to attach by hand.
  Future<String> Function(Uint8List archive, String description)? submit,
  LogScope? log,
}) async {
  final description = await _askWhatHappened(plugin, canSubmit: submit != null);
  if (description == null) return;

  showNotice(S.bugReportCollecting);

  final BugReport report;
  final List<(String, String)> logFiles;
  try {
    (report, logFiles) = await buildReport(description);
  } catch (e) {
    showNotice(S.bugReportFailed(e));
    return;
  }

  // Written into the vault as a gzip archive, and nowhere else.
  //
  // The system share sheet and a browser download were both tried on a real
  // phone and both removed: Obsidian's mobile WebView exposes no Web Share
  // API, and its anchor advertises `download` while silently ignoring it, so
  // the capability cannot even be detected. A vault write is the only delivery
  // whose outcome can be observed and stated truthfully.
  //
  // Compressed because a log is a dozen times smaller gzipped and the file is
  // meant to be sent, not read here. Obsidian will not list a `.gz` in its own
  // explorer, which does not matter: the vault is a real folder on Android and
  // shows up in Files on iOS, so the OS picker Telegram opens can reach it.
  String? savedPath;
  Object? saveError;
  String? reportId;
  String? uploadError;
  try {
    // The summary, then every log file copied verbatim under logs/. Nothing is
    // concatenated: joining them is what forced a size cap, and it erased the
    // boundaries that say which segment a line belongs to.
    final bytes = await buildZip([
      ZipEntry('report.md', report.render()),
      for (final (name, content) in logFiles) ZipEntry('logs/$name', content),
    ]);
    savedPath = await _saveBytesToVault(plugin, report.archiveName, bytes);
    log?.info(
      'report: archived ${logFiles.length + 1} file(s), ${bytes.length} B',
    );

    // Saved first, uploaded second, and deliberately in that order: the file
    // is the outcome we can guarantee, and a user whose upload fails still has
    // something to send. Never the other way round.
    if (submit != null) {
      if (bytes.length > kMaxReportArchiveBytes) {
        uploadError = S.bugReportTooLargeToSend;
        log?.warning('report: too large to upload, ${bytes.length} B');
      } else {
        try {
          reportId = await submit(bytes, description);
          log?.info('report: uploaded as $reportId');
        } catch (e) {
          uploadError = '$e';
          log?.warning('report: upload failed: $e');
        }
      }
    }
  } catch (e) {
    // No uncompressed fallback on purpose. One artifact means one thing to
    // recognise, one name, one exclusion rule; a second format that appears
    // only when something went wrong is a path nobody tests and everybody
    // forgets. Compression already degrades per entry (deflate, then stored),
    // so reaching here means something is genuinely broken and saying so
    // beats quietly handing over a different file.
    saveError = e;
    log?.warning('report: could not write the archive: $e');
  }

  await _showResult(
    plugin,
    summary: report.render(),
    reportId: reportId,
    uploadError: uploadError,
    savedPath: savedPath,
    saveError: saveError,
    openUrl: openUrl,
    supportUrl: supportUrl,
  );
}

/// Returns what the user typed, or null if they backed out. An empty string is
/// a real answer — a report with no description still carries the logs, and
/// demanding prose is a good way to get no report at all.
/// [canSubmit] decides which sentence describes where the report goes.
///
/// Asked rather than glossed over: the report is sent as part of pressing the
/// button, and finding that out afterwards, on the result screen, is exactly
/// the kind of surprise this product does not get to have.
Future<String?> _askWhatHappened(
  PluginHandle plugin, {
  bool canSubmit = false,
}) => showModalWith<String>(
  plugin,
  build: (ctx) {
    ctx.h3(S.bugReportTitle);
    ctx.createEl('p', cls: 'rhyolite-setting-desc', text: S.bugReportIntro);

    final input = ctx.createEl('textarea', cls: 'rhyolite-bug-report-input');
    jsu.setProperty(input, 'placeholder', S.bugReportPlaceholder);
    jsu.setProperty(input, 'rows', 5);

    ctx.createEl('p', cls: 'rhyolite-setting-desc', text: S.bugReportContents);
    ctx.createEl(
      'p',
      cls: 'rhyolite-setting-desc',
      text: canSubmit ? S.bugReportWillSend : S.bugReportWillSaveOnly,
    );
    ctx.spaceVertical(px: 8);

    ctx.buttonRow([
      ButtonSpec(
        S.bugReportCreate,
        () => ctx.close(jsu.getProperty<String?>(input, 'value') ?? ''),
        variant: ButtonVariant.primary,
      ),
      ButtonSpec(S.cancel, () => ctx.close(null)),
    ]);
    ctx.onEscape(() => ctx.close(null));

    jsu.callMethod<void>(input, 'focus', []);
  },
);

Future<void> _showResult(
  PluginHandle plugin, {

  /// `report.md` — the archive's summary, without the logs.
  required String summary,

  /// Set when the archive reached the server; the user quotes this instead of
  /// attaching anything.
  required String? reportId,
  required String? uploadError,
  required String? savedPath,
  required Object? saveError,
  required void Function(String url) openUrl,
  required String supportUrl,
}) => showModalWith<void>(
  plugin,
  build: (ctx) {
    ctx.h3(S.bugReportReadyTitle);

    if (reportId != null) {
      // Sent: there is nothing left for the user to do but say which report.
      ctx.createEl('p', text: S.bugReportSent);
      ctx.createEl('p', cls: 'rhyolite-vault-label', text: reportId);
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: S.bugReportSentHint,
      );
    } else if (savedPath != null) {
      if (uploadError != null) {
        // Say why it is still a file to attach. Silence here would read as
        // "this is how it always works" and cost the upload path its bug.
        ctx.createEl(
          'p',
          cls: 'rhyolite-setting-desc',
          text: S.bugReportNotSent(uploadError),
        );
      }
      ctx.createEl('p', text: S.bugReportSavedTo);
      ctx.createEl('p', cls: 'rhyolite-vault-label', text: savedPath);
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: S.bugReportSendHint,
      );
    } else {
      // The file is the thing the user was promised, so a failure to write
      // it is stated plainly rather than left for them to discover. There is
      // nothing to offer instead: the archive cannot go on the clipboard,
      // and a summary without logs would not be a report.
      ctx.showError(S.bugReportSaveFailed(saveError ?? ''));
    }

    ctx.spaceVertical(px: 8);
    _addSummary(ctx, summary);
    ctx.spaceVertical(px: 8);

    ctx.buttonRow([
      ButtonSpec(S.bugReportOpenTelegram, () {
        ctx.close(null);
        openUrl(supportUrl);
      }, variant: ButtonVariant.primary),
      ButtonSpec(S.close, () => ctx.close(null)),
    ]);
    ctx.onEscape(() => ctx.close(null));
  },
);

/// Shows what the report says about the vault, collapsed.
///
/// This is the summary, not the log. A log preview was tried and removed —
/// scrolling forty thousand lines of `#1234 INF engine: reconcile` tells a
/// person nothing, and calling that consent was theatre. The summary is a
/// screen and a half of plain statements about their own vault: version,
/// file counts, conflicts, plan, and anything that went wrong. That is worth
/// reading, and short enough to be read.
void _addSummary(ModalContext<void> ctx, String summary) {
  final details = ctx.createEl('details');
  final title = jsu.callMethod<JSObject>(details, 'createEl', ['summary']);
  jsu.setProperty(title, 'textContent', S.bugReportSummaryTitle);
  final pre = jsu.callMethod<JSObject>(details, 'createEl', ['pre']);
  jsu.setProperty(pre, 'className', 'rhyolite-bug-report-preview');
  // textContent, never innerHTML — this carries vault names and paths, none of
  // which should ever be parsed as markup.
  jsu.setProperty(pre, 'textContent', summary);
}

/// Writes the archive into the vault root.
///
/// Through the adapter rather than `vault.create`, which only takes text.
/// Obsidian does not index it, which is right — it is a payload to hand over,
/// not a note.
Future<String> _saveBytesToVault(
  PluginHandle plugin,
  String name,
  Uint8List bytes,
) async {
  await plugin.app.vault.adapter.writeBinary(name, bytes);
  return name;
}

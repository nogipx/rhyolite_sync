// ignore_for_file: deprecated_member_use
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_client_account/rhyolite_client_account.dart';
import 'package:rpc_dart/logger.dart';

/// Shows a subscription payment modal.
///
/// Fetches available products from the server, then lets the user pick
/// one. Selecting a plan opens a checkout screen where the user can
/// optionally enter a discount code (with live preview) before going to
/// the payment provider.
///
/// Returns true if payment was initiated.
Future<bool> showPaymentModal(
  PluginHandle plugin, {
  required RpcAccountClient authClient,
  required void Function(String url) openUrl,
}) async {
  final products = await authClient.listProducts();
  if (products.isEmpty) return false;

  final result = await showModalWith<bool>(
    plugin,
    build: (ctx) {
      ctx.h3('Subscribe to Rhyolite Sync');
      ctx.spaceVertical(px: 12);

      for (final product in products) {
        final price =
            '${(product.amountKopecks / 100).toStringAsFixed(0)} ₽'
            ' / ${product.periodDays} days';
        ctx.buttonRow([
          ButtonSpec('${product.name}  ·  $price', () async {
            ctx.close(true);
            await _showCheckout(
              plugin,
              authClient: authClient,
              product: product,
              openUrl: openUrl,
            );
          }, variant: ButtonVariant.primary),
        ]);
        ctx.spaceVertical(px: 4);
      }

      ctx.spaceVertical(px: 8);
      ctx.buttonRow([ButtonSpec('Cancel', () => ctx.close(false))]);
      ctx.onEscape(() => ctx.close(false));
    },
  );
  return result ?? false;
}

/// Per-plan checkout step. Optional discount code with live preview.
/// Final price (after discount) is what's signed by the server and
/// shown on the Selfwork checkout page.
Future<void> _showCheckout(
  PluginHandle plugin, {
  required RpcAccountClient authClient,
  required ProductDto product,
  required void Function(String url) openUrl,
}) async {
  await showModalWith<bool>(
    plugin,
    build: (ctx) {
      ctx.h3(product.name);
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: '${(product.amountKopecks / 100).toStringAsFixed(0)} ₽'
            ' · ${product.periodDays} days',
      );
      ctx.spaceVertical(px: 12);

      ctx.createEl('p', text: 'Promo code (optional):');
      final codeInput = ctx.input(placeholder: 'e.g. WELCOME20');
      ctx.spaceVertical(px: 6);

      final previewLine = ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: '',
      );

      String? appliedCode;

      void setPreviewText(String text) {
        jsu.setProperty(previewLine, 'textContent', text);
      }

      Future<void> applyCode() async {
        final raw = ctx.valueOf(codeInput).trim();
        if (raw.isEmpty) {
          appliedCode = null;
          setPreviewText('');
          return;
        }
        setPreviewText('Checking…');
        try {
          final response = await authClient.previewDiscount(
            code: raw,
            planId: product.planId,
            originalKopecks: product.amountKopecks,
          );
          if (response.application != null) {
            final app = response.application!;
            appliedCode = raw;
            final original =
                (app.originalKopecks / 100).toStringAsFixed(0);
            final discount =
                (app.discountKopecks / 100).toStringAsFixed(0);
            final finalRub = (app.finalKopecks / 100).toStringAsFixed(0);
            setPreviewText(
              'Discount applied: −$discount ₽. '
              'Total: $finalRub ₽ (was $original ₽).',
            );
          } else {
            appliedCode = null;
            setPreviewText(
              'Invalid code: ${_humanReason(response.errorReason)}.',
            );
          }
        } catch (e) {
          appliedCode = null;
          setPreviewText('Could not check code: $e');
        }
      }

      Future<void> pay() async {
        try {
          final url = await authClient.createPayment(
            planId: product.planId,
            discountCode: appliedCode,
          );
          if (url == null || url.isEmpty) {
            ctx.close(true);
            return;
          }
          openUrl(url);
          ctx.close(true);
        } catch (e) {
          ctx.showError('Failed to create payment: $e');
        }
      }

      ctx.buttonRow([
        ButtonSpec('Apply code', applyCode),
      ]);
      ctx.spaceVertical(px: 12);

      ctx.buttonRow([
        ButtonSpec('Pay', pay, variant: ButtonVariant.primary),
        ButtonSpec('Cancel', () => ctx.close(false)),
      ]);
      ctx
        ..onEnter(codeInput, applyCode)
        ..onEscape(() => ctx.close(false));
    },
  );
}

String _humanReason(String? reason) {
  switch (reason) {
    case 'not_found':
      return 'unknown code';
    case 'code_inactive':
      return 'code disabled';
    case 'code_not_started':
      return 'code not active yet';
    case 'code_expired':
      return 'code expired';
    case 'code_exhausted':
      return 'code is fully used';
    case 'wrong_plan':
      return 'code does not apply to this plan';
    case 'wrong_user':
      return 'code is for another user';
    case 'order_too_small':
      return 'order amount below minimum';
    case 'user_limit_reached':
      return 'you have already used this code';
    default:
      return reason ?? 'unknown reason';
  }
}

/// Returns the subscription end date if active, null otherwise.
Future<DateTime?> checkSubscription(
  RpcAccountClient authClient, {
  LogScope? logger,
}) async {
  try {
    final sub = await authClient.getSubscription();
    if (!sub.isActive || sub.currentPeriodEnd == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      sub.currentPeriodEnd! * 1000,
    ).toLocal();
  } catch (e) {
    (logger ?? LogScope.noop).error('checkSubscription error', error: e);
    return null;
  }
}

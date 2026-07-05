// ignore_for_file: uri_has_not_been_generated

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import '../models/plan_capabilities.dart';

part 'subscription_contract.g.dart';

// --- DTOs ---

enum SubscriptionStatus { active, expired, none }

class SubscriptionDto implements IRpcSerializable {
  const SubscriptionDto({
    required this.status,
    this.currentPeriodEnd,
    this.plan,
    this.capabilities,
  });

  final SubscriptionStatus status;

  /// Unix timestamp (seconds) when the current period ends. Null if no subscription.
  final int? currentPeriodEnd;

  final String? plan;

  /// Capability snapshot for the active plan. `null` when the user has
  /// no subscription or when the server failed to resolve a plan; client
  /// callers should treat that as "no client-side hint about limits" and
  /// fall back to the server's per-request enforcement.
  ///
  /// Used by the plugin's file-size decorator to pre-emptively mark
  /// blocked files in the explorer, and by the UI to surface storage
  /// quotas without an extra round-trip.
  final PlanCapabilities? capabilities;

  bool get isActive => status == SubscriptionStatus.active;

  factory SubscriptionDto.fromJson(Map<String, dynamic> json) =>
      SubscriptionDto(
        status: SubscriptionStatus.values.byName(json['status'] as String),
        currentPeriodEnd: (json['current_period_end'] as num?)?.toInt(),
        plan: json['plan'] as String?,
        capabilities: json['capabilities'] is Map
            ? PlanCapabilities.fromJson(
                Map<String, dynamic>.from(json['capabilities'] as Map),
              )
            : null,
      );

  @override
  Map<String, dynamic> toJson() => {
    'status': status.name,
    if (currentPeriodEnd != null) 'current_period_end': currentPeriodEnd,
    if (plan != null) 'plan': plan,
    if (capabilities != null) 'capabilities': capabilities!.toJson(),
  };
}

class InvoiceDto implements IRpcSerializable {
  const InvoiceDto({
    required this.invoiceId,
    required this.amount,
    required this.currency,
    required this.status,
    required this.createdAt,
  });

  final String invoiceId;
  final int amount;
  final String currency;
  final String status;

  /// Unix timestamp (seconds).
  final int createdAt;

  factory InvoiceDto.fromJson(Map<String, dynamic> json) => InvoiceDto(
    invoiceId: json['invoice_id'] as String,
    amount: (json['amount'] as num).toInt(),
    currency: json['currency'] as String,
    status: json['status'] as String,
    createdAt: (json['created_at'] as num).toInt(),
  );

  @override
  Map<String, dynamic> toJson() => {
    'invoice_id': invoiceId,
    'amount': amount,
    'currency': currency,
    'status': status,
    'created_at': createdAt,
  };
}

class GetSubscriptionRequest implements IRpcSerializable {
  const GetSubscriptionRequest();

  factory GetSubscriptionRequest.fromJson(Map<String, dynamic> _) =>
      const GetSubscriptionRequest();

  @override
  Map<String, dynamic> toJson() => const {};
}

class ListInvoicesRequest implements IRpcSerializable {
  const ListInvoicesRequest();

  factory ListInvoicesRequest.fromJson(Map<String, dynamic> _) =>
      const ListInvoicesRequest();

  @override
  Map<String, dynamic> toJson() => const {};
}

class ListInvoicesResponse implements IRpcSerializable {
  const ListInvoicesResponse({required this.invoices});

  final List<InvoiceDto> invoices;

  factory ListInvoicesResponse.fromJson(Map<String, dynamic> json) =>
      ListInvoicesResponse(
        invoices: (json['invoices'] as List)
            .cast<Map<String, dynamic>>()
            .map(InvoiceDto.fromJson)
            .toList(),
      );

  @override
  Map<String, dynamic> toJson() => {
    'invoices': invoices.map((i) => i.toJson()).toList(),
  };
}

class ProductDto implements IRpcSerializable {
  const ProductDto({
    required this.planId,
    required this.name,
    required this.amountKopecks,
    required this.periodDays,
  });

  final String planId;
  final String name;
  final int amountKopecks;
  final int periodDays;

  factory ProductDto.fromJson(Map<String, dynamic> json) => ProductDto(
    planId: json['plan_id'] as String,
    name: json['name'] as String,
    amountKopecks: (json['amount_kopecks'] as num).toInt(),
    periodDays: (json['period_days'] as num).toInt(),
  );

  @override
  Map<String, dynamic> toJson() => {
    'plan_id': planId,
    'name': name,
    'amount_kopecks': amountKopecks,
    'period_days': periodDays,
  };
}

class ListProductsRequest implements IRpcSerializable {
  const ListProductsRequest();

  factory ListProductsRequest.fromJson(Map<String, dynamic> _) =>
      const ListProductsRequest();

  @override
  Map<String, dynamic> toJson() => const {};
}

class ListProductsResponse implements IRpcSerializable {
  const ListProductsResponse({required this.products});

  final List<ProductDto> products;

  factory ListProductsResponse.fromJson(Map<String, dynamic> json) =>
      ListProductsResponse(
        products: (json['products'] as List)
            .cast<Map<String, dynamic>>()
            .map(ProductDto.fromJson)
            .toList(),
      );

  @override
  Map<String, dynamic> toJson() => {
    'products': products.map((p) => p.toJson()).toList(),
  };
}

class CreatePaymentRequest implements IRpcSerializable {
  const CreatePaymentRequest({required this.planId, this.discountCode});

  /// Identifier of the plan/product to purchase (matches [SelfworkProduct.planId]).
  final String planId;

  /// Optional discount code to apply at checkout. Validated and applied
  /// server-side; if invalid, the createPayment call fails with an
  /// `invalid_argument` RpcException carrying the reason.
  final String? discountCode;

  factory CreatePaymentRequest.fromJson(Map<String, dynamic> json) =>
      CreatePaymentRequest(
        planId: json['plan_id'] as String,
        discountCode: json['discount_code'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
    'plan_id': planId,
    if (discountCode != null) 'discount_code': discountCode,
  };
}

class CreatePaymentResponse implements IRpcSerializable {
  const CreatePaymentResponse({this.paymentUrl});

  /// Redirect URL to the payment page.
  /// Null when payment is processed without redirect (e.g. dev simulation).
  final String? paymentUrl;

  factory CreatePaymentResponse.fromJson(Map<String, dynamic> json) =>
      CreatePaymentResponse(paymentUrl: json['payment_url'] as String?);

  @override
  Map<String, dynamic> toJson() => {
    if (paymentUrl != null) 'payment_url': paymentUrl,
  };
}

class RestoreSubscriptionRequest implements IRpcSerializable {
  const RestoreSubscriptionRequest();

  factory RestoreSubscriptionRequest.fromJson(Map<String, dynamic> _) =>
      const RestoreSubscriptionRequest();

  @override
  Map<String, dynamic> toJson() => const {};
}

class RestoreSubscriptionResponse implements IRpcSerializable {
  const RestoreSubscriptionResponse({required this.restored, this.message});

  /// True if at least one pending payment was found succeeded and subscription activated.
  final bool restored;

  /// Human-readable message explaining the result.
  final String? message;

  factory RestoreSubscriptionResponse.fromJson(Map<String, dynamic> json) =>
      RestoreSubscriptionResponse(
        restored: json['restored'] as bool,
        message: json['message'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
    'restored': restored,
    if (message != null) 'message': message,
  };
}

// --- Contract ---

/// Subscription and billing contract — JWT required.
@RpcService(
  name: 'RhyoliteSubscription',
  transferMode: RpcDataTransferMode.codec,
)
abstract class ISubscriptionContract {
  @RpcMethod.unary(name: 'getSubscription')
  Future<SubscriptionDto> getSubscription(
    GetSubscriptionRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'listInvoices')
  Future<ListInvoicesResponse> listInvoices(
    ListInvoicesRequest request, {
    RpcContext? context,
  });

  /// Returns available products/plans. Does not require authentication.
  @RpcMethod.unary(name: 'listProducts')
  Future<ListProductsResponse> listProducts(
    ListProductsRequest request, {
    RpcContext? context,
  });

  /// Create a payment session and return the payment URL.
  @RpcMethod.unary(name: 'createPayment')
  Future<CreatePaymentResponse> createPayment(
    CreatePaymentRequest request, {
    RpcContext? context,
  });

  /// Check pending payments against the payment provider and activate
  /// subscription if any succeeded. Use when webhook was missed.
  @RpcMethod.unary(name: 'restoreSubscription')
  Future<RestoreSubscriptionResponse> restoreSubscription(
    RestoreSubscriptionRequest request, {
    RpcContext? context,
  });
}

namespace OrderPipeline.Functions.Orders;

/// <summary>Inbound HTTP payload. Fields are nullable so validation can report what's missing instead of failing deserialization.</summary>
public sealed record OrderRequest(Guid? OrderId, string? CustomerId, IReadOnlyList<OrderLineRequest>? Items);

public sealed record OrderLineRequest(string? Sku, int Quantity, decimal UnitPrice);

/// <summary>Message published to Service Bus once an order has passed validation.</summary>
public sealed record OrderSubmitted(
    Guid OrderId,
    string CustomerId,
    IReadOnlyList<OrderLine> Items,
    decimal Total,
    DateTimeOffset SubmittedAtUtc);

public sealed record OrderLine(string Sku, int Quantity, decimal UnitPrice);

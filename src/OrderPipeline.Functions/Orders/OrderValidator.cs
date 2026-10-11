namespace OrderPipeline.Functions.Orders;

public static class OrderValidator
{
    public const int MaxCustomerIdLength = 64;
    public const int MaxSkuLength = 50;
    public const int MaxItems = 100;
    public const int MaxQuantity = 1_000;
    public const decimal MaxUnitPrice = 1_000_000m;

    /// <summary>Returns field-keyed validation errors; empty when the order is valid.</summary>
    public static Dictionary<string, string[]> Validate(OrderRequest? order)
    {
        var errors = new Dictionary<string, List<string>>();
        void Add(string field, string message) =>
            (errors.TryGetValue(field, out var list) ? list : errors[field] = []).Add(message);

        if (order is null)
        {
            Add("body", "Request body is required.");
            return Flatten(errors);
        }

        if (order.OrderId is null || order.OrderId == Guid.Empty)
            Add("orderId", "orderId is required and must be a non-empty GUID.");

        if (string.IsNullOrWhiteSpace(order.CustomerId))
            Add("customerId", "customerId is required.");
        else if (order.CustomerId.Length > MaxCustomerIdLength)
            Add("customerId", $"customerId must be at most {MaxCustomerIdLength} characters.");

        if (order.Items is null || order.Items.Count == 0)
        {
            Add("items", "At least one item is required.");
        }
        else
        {
            if (order.Items.Count > MaxItems)
                Add("items", $"At most {MaxItems} items are allowed.");

            for (var i = 0; i < order.Items.Count; i++)
            {
                var item = order.Items[i];
                var prefix = $"items[{i}]";
                if (item is null)
                {
                    Add(prefix, "Item cannot be null.");
                    continue;
                }
                if (string.IsNullOrWhiteSpace(item.Sku))
                    Add($"{prefix}.sku", "sku is required.");
                else if (item.Sku.Length > MaxSkuLength)
                    Add($"{prefix}.sku", $"sku must be at most {MaxSkuLength} characters.");
                if (item.Quantity is < 1 or > MaxQuantity)
                    Add($"{prefix}.quantity", $"quantity must be between 1 and {MaxQuantity}.");
                if (item.UnitPrice <= 0 || item.UnitPrice > MaxUnitPrice)
                    Add($"{prefix}.unitPrice", $"unitPrice must be greater than 0 and at most {MaxUnitPrice}.");
            }
        }

        return Flatten(errors);
    }

    private static Dictionary<string, string[]> Flatten(Dictionary<string, List<string>> errors) =>
        errors.ToDictionary(e => e.Key, e => e.Value.ToArray());
}

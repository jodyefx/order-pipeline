using System.Text.Json;
using Azure.Messaging.ServiceBus;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace OrderPipeline.Functions.Orders;

public sealed class SubmitOrder(ServiceBusSender ordersSender, ILogger<SubmitOrder> logger)
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    [Function(nameof(SubmitOrder))]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "orders")] HttpRequest req,
        CancellationToken cancellationToken)
    {
        OrderRequest? request;
        try
        {
            request = await JsonSerializer.DeserializeAsync<OrderRequest>(req.Body, Json, cancellationToken);
        }
        catch (JsonException ex)
        {
            return new BadRequestObjectResult(new ValidationProblemDetails(
                new Dictionary<string, string[]> { ["body"] = [$"Malformed JSON: {ex.Message}"] }));
        }

        var errors = OrderValidator.Validate(request);
        if (errors.Count > 0)
            return new BadRequestObjectResult(new ValidationProblemDetails(errors));

        var order = new OrderSubmitted(
            request!.OrderId!.Value,
            request.CustomerId!.Trim(),
            request.Items!.Select(i => new OrderLine(i.Sku!.Trim(), i.Quantity, i.UnitPrice)).ToList(),
            request.Items!.Sum(i => i.Quantity * i.UnitPrice),
            DateTimeOffset.UtcNow);

        // MessageId = OrderId: a client retrying the same order produces the same message ID,
        // which the consumer uses as its idempotency key.
        var message = new ServiceBusMessage(BinaryData.FromObjectAsJson(order, Json))
        {
            MessageId = order.OrderId.ToString(),
            ContentType = "application/json",
            Subject = nameof(OrderSubmitted),
        };

        await ordersSender.SendMessageAsync(message, cancellationToken);
        logger.LogInformation("Published order {OrderId} for customer {CustomerId} (total {Total})",
            order.OrderId, order.CustomerId, order.Total);

        return new AcceptedResult(location: null, new { order.OrderId, status = "Accepted" });
    }
}

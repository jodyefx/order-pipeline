// Looks for a message by MessageId on a Service Bus queue without consuming it.
// Usage: dotnet run peek-queue.cs -- <messageId> [queueName]
// Prints the message as JSON and exits 0 if found; exits 1 if not found.
#:package Azure.Messaging.ServiceBus@7.21.0
#:property JsonSerializerIsReflectionEnabledByDefault=true
using System.Text.Json;
using Azure.Messaging.ServiceBus;

const string Connection = "Endpoint=sb://localhost;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;";

if (args.Length < 1)
{
    Console.Error.WriteLine("Usage: dotnet run peek-queue.cs -- <messageId> [queueName]");
    return 2;
}

var messageId = args[0];
var queue = args.Length > 1 ? args[1] : "orders";

await using var client = new ServiceBusClient(Connection);
await using var receiver = client.CreateReceiver(queue);

// Peek through the queue in pages; peeking never locks or removes messages.
long? fromSequence = null;
while (true)
{
    var page = fromSequence is null
        ? await receiver.PeekMessagesAsync(100)
        : await receiver.PeekMessagesAsync(100, fromSequence);
    if (page.Count == 0) break;

    var match = page.FirstOrDefault(m => m.MessageId == messageId);
    if (match is not null)
    {
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            match.MessageId,
            match.Subject,
            match.ContentType,
            Body = JsonDocument.Parse(match.Body.ToString()).RootElement,
        }));
        return 0;
    }
    fromSequence = page[^1].SequenceNumber + 1;
}

return 1;

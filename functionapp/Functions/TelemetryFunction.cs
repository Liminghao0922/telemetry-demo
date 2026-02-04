using System.Net;
using System.Text.Json;
using Microsoft.Azure.Cosmos;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Telemetry.FunctionApp.Models;

namespace Telemetry.FunctionApp.Functions;

public class TelemetryFunction
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly CosmosClient _cosmosClient;
    private readonly IConfiguration _configuration;
    private readonly ILogger _logger;

    public TelemetryFunction(
        CosmosClient cosmosClient,
        IConfiguration configuration,
        ILoggerFactory loggerFactory)
    {
        _cosmosClient = cosmosClient;
        _configuration = configuration;
        _logger = loggerFactory.CreateLogger<TelemetryFunction>();
    }

    [Function("TelemetryIngest")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "telemetry")] HttpRequestData req)
    {
        var body = await new StreamReader(req.Body).ReadToEndAsync();
        if (string.IsNullOrWhiteSpace(body))
        {
            return CreateError(req, HttpStatusCode.BadRequest, "Request body is required.");
        }

        TelemetryPayload? payload;
        try
        {
            payload = JsonSerializer.Deserialize<TelemetryPayload>(body, JsonOptions);
        }
        catch (JsonException ex)
        {
            _logger.LogWarning(ex, "Failed to deserialize payload.");
            return CreateError(req, HttpStatusCode.BadRequest, "Invalid JSON format.");
        }

        var validationError = Validate(payload);
        if (!string.IsNullOrEmpty(validationError))
        {
            return CreateError(req, HttpStatusCode.BadRequest, validationError);
        }

        payload!.Id ??= Guid.NewGuid().ToString("N");
        payload.ReceivedAt = DateTimeOffset.UtcNow;

        var databaseName = _configuration["CosmosDb:DatabaseName"] ?? "telemetrydb";
        var containerName = _configuration["CosmosDb:ContainerName"] ?? "telemetry";
        var container = _cosmosClient.GetContainer(databaseName, containerName);

        await container.CreateItemAsync(payload, new PartitionKey(payload.DeviceId));

        var response = req.CreateResponse(HttpStatusCode.Created);
        await response.WriteAsJsonAsync(new
        {
            id = payload.Id,
            deviceId = payload.DeviceId,
            timestamp = payload.Timestamp
        });

        return response;
    }

    private static string? Validate(TelemetryPayload? payload)
    {
        if (payload is null)
        {
            return "Payload is required.";
        }

        if (string.IsNullOrWhiteSpace(payload.DeviceId))
        {
            return "deviceId is required.";
        }

        if (payload.Timestamp == default)
        {
            return "timestamp is required.";
        }

        if (payload.Metrics is null || payload.Metrics.Count == 0)
        {
            return "metrics is required.";
        }

        return null;
    }

    private static HttpResponseData CreateError(HttpRequestData req, HttpStatusCode status, string message)
    {
        var response = req.CreateResponse(status);
        response.WriteString(message);
        return response;
    }
}

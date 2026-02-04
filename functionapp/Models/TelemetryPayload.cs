using System.Text.Json;
using System.Text.Json.Serialization;

namespace Telemetry.FunctionApp.Models;

public class TelemetryPayload
{
    [JsonPropertyName("id")]
    public string? Id { get; set; }

    [JsonPropertyName("deviceId")]
    public string DeviceId { get; set; } = string.Empty;

    [JsonPropertyName("timestamp")]
    public DateTimeOffset Timestamp { get; set; }

    [JsonPropertyName("type")]
    public string? Type { get; set; }

    [JsonPropertyName("source")]
    public string? Source { get; set; }

    [JsonPropertyName("tags")]
    public Dictionary<string, string>? Tags { get; set; }

    [JsonPropertyName("metrics")]
    public Dictionary<string, JsonElement>? Metrics { get; set; }

    [JsonPropertyName("receivedAt")]
    public DateTimeOffset? ReceivedAt { get; set; }
}

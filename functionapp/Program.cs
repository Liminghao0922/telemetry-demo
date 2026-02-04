using Azure.Identity;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Telemetry.FunctionApp.Infrastructure;

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .ConfigureServices(services =>
    {
        services.AddSingleton(sp =>
        {
            var configuration = sp.GetRequiredService<IConfiguration>();
            var endpoint = configuration["CosmosDb:AccountEndpoint"];
            if (string.IsNullOrWhiteSpace(endpoint))
            {
                throw new InvalidOperationException("CosmosDb:AccountEndpoint is not configured.");
            }

            CosmosClient cosmosClient;

            // For local development with Cosmos DB Emulator
            var key = configuration["CosmosDb:AccountKey"];
            if (!string.IsNullOrWhiteSpace(key))
            {
                cosmosClient = new CosmosClient(endpoint, key, new CosmosClientOptions
                {
                    ApplicationName = "Telemetry.FunctionApp",
                    Serializer = new CosmosSystemTextJsonSerializer(new System.Text.Json.JsonSerializerOptions
                    {
                        PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase,
                        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
                    }),
                    HttpClientFactory = () => new HttpClient(new HttpClientHandler
                    {
                        ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
                    })
                });
            }
            else
            {
                // For Azure with Managed Identity
                cosmosClient = new CosmosClient(endpoint, new DefaultAzureCredential(), new CosmosClientOptions
                {
                    ApplicationName = "Telemetry.FunctionApp",
                    Serializer = new CosmosSystemTextJsonSerializer(new System.Text.Json.JsonSerializerOptions
                    {
                        PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase,
                        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
                    })
                });
            }

            // Ensure database and container exist
            EnsureCosmosDbResourcesAsync(cosmosClient, configuration).GetAwaiter().GetResult();

            return cosmosClient;
        });
    })
    .Build();

host.Run();

static async Task EnsureCosmosDbResourcesAsync(CosmosClient cosmosClient, IConfiguration configuration)
{
    var databaseName = configuration["CosmosDb:DatabaseName"] ?? "telemetrydb";
    var containerName = configuration["CosmosDb:ContainerName"] ?? "telemetry";
    var partitionKeyPath = configuration["CosmosDb:PartitionKeyPath"] ?? "/deviceId";

    // Create database if not exists
    var databaseResponse = await cosmosClient.CreateDatabaseIfNotExistsAsync(databaseName);
    Console.WriteLine($"Database '{databaseName}' ready (Status: {databaseResponse.StatusCode})");

    // Create container if not exists
    var database = cosmosClient.GetDatabase(databaseName);
    var containerResponse = await database.CreateContainerIfNotExistsAsync(
        containerName,
        partitionKeyPath);
    Console.WriteLine($"Container '{containerName}' ready (Status: {containerResponse.StatusCode})");
}

using Microsoft.AspNetCore.Mvc;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;
using Serilog;
using Serilog.Events;
using System.Diagnostics;
using System.Text;
using System.Text.Json;

// ---------- Serilog bootstrap ----------
Log.Logger = new LoggerConfiguration()
    .MinimumLevel.Override("Microsoft", LogEventLevel.Information)
    .Enrich.FromLogContext()
    .Enrich.With(new ActivityEnricher())
    .WriteTo.Console(outputTemplate:
        "[{Timestamp:HH:mm:ss} {Level:u3}] {Message:lj} | TraceId={TraceId} SpanId={SpanId}{NewLine}{Exception}")
    .CreateLogger();

var builder = WebApplication.CreateBuilder(args);

builder.Host.UseSerilog();

// Add services to the container.
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddOpenApi();

var serviceName = builder.Configuration["OTEL_SERVICE_NAME"] ?? "newapp";

// RabbitMQ connection setup
builder.Services.AddSingleton<IConnectionFactory>(sp =>
{
    return new ConnectionFactory
    {
        HostName = builder.Configuration["RABBITMQ_HOST"] ?? "rabbitmq"
    };
});

// Register RabbitMQ Consumer as a Hosted Service
builder.Services.AddHostedService<RabbitMqConsumerService>();

var app = builder.Build();

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

// ---------- Global exception handler ----------
app.Use(async (context, next) =>
{
    try
    {
        await next(context);
    }
    catch (Exception ex)
    {
        var activity = Activity.Current;
        activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
        activity?.AddEvent(new ActivityEvent("exception", tags: new ActivityTagsCollection
        {
            { "exception.type", ex.GetType().FullName },
            { "exception.message", ex.Message },
            { "exception.stacktrace", ex.StackTrace ?? "" }
        }));

        Log.Error(ex, "Unhandled exception on {Path}", context.Request.Path);

        context.Response.StatusCode = 500;
        await context.Response.WriteAsJsonAsync(new
        {
            error = ex.GetType().Name,
            message = ex.Message,
            traceId = activity?.TraceId.ToString()
        });
    }
});

app.MapGet("/api/health", () => Results.Ok(new { status = "healthy", service = serviceName }))
.WithName("GetHealth")
.WithOpenApi();

app.MapPost("/api/newapp/process", ([FromBody] ProcessRequest request) =>
{
    using var activity = new ActivitySource("NewApp").StartActivity("ProcessRequest");
    
    // Simulate failing if data is invalid or missing
    if (string.IsNullOrEmpty(request.Data))
    {
        activity?.SetStatus(ActivityStatusCode.Error, "Missing data in request");
        throw new ArgumentException("Data cannot be null or empty. Bad Request from upstream.");
    }
    
    return Results.Ok(new { success = true, message = $"Processed {request.Data}" });
})
.WithName("ProcessData")
.WithOpenApi();

app.Run();

// Request DTO
public class ProcessRequest
{
    public string? Data { get; set; }
}

// Background Service for RabbitMQ
public class RabbitMqConsumerService : BackgroundService
{
    private readonly IConnectionFactory _connectionFactory;
    private readonly ILogger<RabbitMqConsumerService> _logger;
    private IConnection? _connection;
    private IChannel? _channel;
    private static readonly ActivitySource ActivitySource = new("NewApp");

    public RabbitMqConsumerService(IConnectionFactory connectionFactory, ILogger<RabbitMqConsumerService> logger)
    {
        _connectionFactory = connectionFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            // Retry connecting to RabbitMQ since it might not be ready immediately
            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    _connection = await _connectionFactory.CreateConnectionAsync(stoppingToken);
                    _channel = await _connection.CreateChannelAsync(cancellationToken: stoppingToken);
                    await _channel.QueueDeclareAsync(queue: "newapp-queue", durable: false, exclusive: false, autoDelete: false, arguments: null, cancellationToken: stoppingToken);
                    _logger.LogInformation("Connected to RabbitMQ and declared 'newapp-queue'.");
                    break;
                }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex, "Failed to connect to RabbitMQ. Retrying in 5 seconds...");
                    await Task.Delay(5000, stoppingToken);
                }
            }

            if (_channel == null) return;

            var consumer = new AsyncEventingBasicConsumer(_channel);
            consumer.ReceivedAsync += async (model, ea) =>
            {
                using var activity = ActivitySource.StartActivity("ProcessRabbitMqMessage");
                
                var body = ea.Body.ToArray();
                var message = Encoding.UTF8.GetString(body);
                
                _logger.LogInformation("Received message: {Message}", message);

                try
                {
                    if (message.Contains("error"))
                    {
                        throw new InvalidOperationException("Simulated error while processing RabbitMQ message: " + message);
                    }
                    
                    _logger.LogInformation("Message processed successfully.");
                    await _channel.BasicAckAsync(deliveryTag: ea.DeliveryTag, multiple: false, cancellationToken: stoppingToken);
                }
                catch (Exception ex)
                {
                    activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
                    activity?.AddEvent(new ActivityEvent("exception", tags: new ActivityTagsCollection
                    {
                        { "exception.type", ex.GetType().FullName },
                        { "exception.message", ex.Message },
                        { "exception.stacktrace", ex.StackTrace ?? "" }
                    }));
                    _logger.LogError(ex, "Error processing message");
                    
                    // Reject the message (could requeue, but we drop it for this simulation to avoid infinite loops)
                    await _channel.BasicRejectAsync(deliveryTag: ea.DeliveryTag, requeue: false, cancellationToken: stoppingToken);
                }
            };

            await _channel.BasicConsumeAsync(queue: "newapp-queue", autoAck: false, consumer: consumer, cancellationToken: stoppingToken);

            // Wait until cancellation is requested
            await Task.Delay(-1, stoppingToken);
        }
        catch (TaskCanceledException)
        {
             _logger.LogInformation("RabbitMQ Consumer Service stopping.");
        }
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        if (_channel != null) await _channel.CloseAsync(cancellationToken: cancellationToken);
        if (_connection != null) await _connection.CloseAsync(cancellationToken: cancellationToken);
        await base.StopAsync(cancellationToken);
    }
}

// ---------- Serilog enricher for Activity TraceId / SpanId ----------
public class ActivityEnricher : Serilog.Core.ILogEventEnricher
{
    public void Enrich(Serilog.Events.LogEvent logEvent, Serilog.Core.ILogEventPropertyFactory factory)
    {
        var activity = Activity.Current;
        logEvent.AddPropertyIfAbsent(factory.CreateProperty("TraceId", activity?.TraceId.ToString() ?? "00000000000000000000000000000000"));
        logEvent.AddPropertyIfAbsent(factory.CreateProperty("SpanId", activity?.SpanId.ToString() ?? "0000000000000000"));
    }
}

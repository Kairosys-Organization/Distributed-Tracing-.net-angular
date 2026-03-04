using Serilog;
using Serilog.Events;
using System.Diagnostics;
using Microsoft.EntityFrameworkCore;
using PathfinderApi.Models;
using RabbitMQ.Client;

// ---------- Serilog bootstrap ----------
Log.Logger = new LoggerConfiguration()
    .MinimumLevel.Override("Microsoft", LogEventLevel.Information)
    .Enrich.FromLogContext()
    .Enrich.With(new ActivityEnricher())
    .WriteTo.Console(outputTemplate:
        "[{Timestamp:HH:mm:ss} {Level:u3}] {Message:lj} | TraceId={TraceId} SpanId={SpanId}{NewLine}{Exception}")
    .CreateLogger();

try
{
    var builder = WebApplication.CreateBuilder(args);

    builder.Host.UseSerilog();

    // ---------- Services ----------
    // No OpenTelemetry code needed!
    // Auto-instrumentation handles tracing via CLR profiler + environment variables.
    builder.Services.AddControllers();
    builder.Services.AddHttpClient();
    builder.Services.AddOpenApi();
    
    // ---------- RabbitMQ ----------
    builder.Services.AddSingleton<IConnectionFactory>(sp =>
    {
        return new ConnectionFactory
        {
            HostName = builder.Configuration["RABBITMQ_HOST"] ?? "rabbitmq"
        };
    });
    
    // ---------- Database ----------
    builder.Services.AddDbContext<AppDbContext>(opts => 
        opts.UseInMemoryDatabase("PathfinderDb"));

    // ---------- CORS ----------
    builder.Services.AddCors(opts =>
    {
        opts.AddPolicy("AllowAngular", policy =>
        {
            policy.WithOrigins("http://localhost:4200", "http://localhost:4201")
                  .AllowAnyHeader()
                  .AllowAnyMethod()
                  .AllowCredentials();
        });
    });

    var app = builder.Build();

    app.UseCors("AllowAngular");

    if (app.Environment.IsDevelopment())
    {
        app.MapOpenApi();
    }

    // ---------- Seed Data ----------
    using (var scope = app.Services.CreateScope())
    {
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        db.Database.EnsureCreated();

        if (!db.Users.Any())
        {
            db.Users.Add(new User 
            { 
                Email = "john@example.com", 
                FullName = "John Doe" 
            });
            db.Users.Add(new User 
            { 
                Email = "admin@pathfinder.local", 
                FullName = "System Administrator" 
            });
            
            db.SaveChanges();
            Log.Information("Pre-populated InMemory H2-style database with initial users.");
        }
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

    app.MapControllers();

    app.Run();
}
catch (Exception ex)
{
    Log.Fatal(ex, "Application terminated unexpectedly");
}
finally
{
    Log.CloseAndFlush();
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

using Microsoft.AspNetCore.Mvc;
using System.Diagnostics;
using System.Text.Json;

namespace PathfinderApi.Controllers;

[ApiController]
[Route("api/errors")]
public class ErrorSimulationController : ControllerBase
{
    private static readonly ActivitySource ActivitySource = new("PathfinderApi");
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly ILogger<ErrorSimulationController> _logger;

    public ErrorSimulationController(IHttpClientFactory httpClientFactory, ILogger<ErrorSimulationController> logger)
    {
        _httpClientFactory = httpClientFactory;
        _logger = logger;
    }

    // ── 1. Unhandled Exception ──────────────────────────────────────
    [HttpGet("unhandled-exception")]
    public IActionResult UnhandledException()
    {
        using var activity = ActivitySource.StartActivity("SimulateUnhandledException");

        _logger.LogInformation("Triggering unhandled NullReferenceException");

        string? value = null;
        _ = value!.Length; // throws NullReferenceException

        return Ok(); // never reached
    }

    // ── 2. Handled Exception ────────────────────────────────────────
    [HttpGet("handled-exception")]
    public IActionResult HandledException()
    {
        using var activity = ActivitySource.StartActivity("SimulateHandledException");

        try
        {
            throw new InvalidOperationException("Simulated handled exception");
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
            _logger.LogError(ex, "Handled exception occurred");

            return StatusCode(500, new
            {
                error = "HandledException",
                message = ex.Message,
                traceId = Activity.Current?.TraceId.ToString()
            });
        }
    }

    // ── 3. SQL / Database Error ─────────────────────────────────────
    [HttpGet("sql-error")]
    public IActionResult SqlError()
    {
        using var activity = ActivitySource.StartActivity("SimulateSqlError");

        try
        {
            // Simulate a database connection failure
            throw new Exception("Database connection failed: Unable to connect to server 'db-server:5432'. Connection refused.");
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
            activity?.SetTag("db.system", "postgresql");
            activity?.SetTag("db.statement", "SELECT * FROM users WHERE id = @id");
            _logger.LogError(ex, "Database error occurred");

            return StatusCode(500, new
            {
                error = "DatabaseError",
                message = ex.Message,
                traceId = Activity.Current?.TraceId.ToString()
            });
        }
    }

    // ── 4. Timeout (long delay) ─────────────────────────────────────
    [HttpGet("timeout")]
    public async Task<IActionResult> Timeout()
    {
        using var activity = ActivitySource.StartActivity("SimulateTimeout");
        activity?.SetTag("timeout.duration_ms", 30000);

        _logger.LogWarning("Starting 30-second timeout simulation");

        await Task.Delay(30000); // 30 seconds

        return Ok(new { message = "Completed after timeout delay" });
    }

    // ── 5. CPU Spike ────────────────────────────────────────────────
    [HttpGet("cpu-spike")]
    public IActionResult CpuSpike()
    {
        using var activity = ActivitySource.StartActivity("SimulateCpuSpike");
        activity?.SetTag("cpu.duration_seconds", 3);

        _logger.LogWarning("Starting CPU spike simulation (3 seconds)");

        var sw = Stopwatch.StartNew();
        while (sw.Elapsed.TotalSeconds < 3)
        {
            // Busy-wait to consume CPU
            _ = Math.Sqrt(Random.Shared.NextDouble());
        }

        activity?.SetTag("cpu.actual_duration_ms", sw.ElapsedMilliseconds);
        _logger.LogInformation("CPU spike completed after {Duration}ms", sw.ElapsedMilliseconds);

        return Ok(new
        {
            message = "CPU spike simulation completed",
            durationMs = sw.ElapsedMilliseconds,
            traceId = Activity.Current?.TraceId.ToString()
        });
    }

    // ── 6. Memory Spike ─────────────────────────────────────────────
    [HttpGet("memory-spike")]
    public IActionResult MemorySpike()
    {
        using var activity = ActivitySource.StartActivity("SimulateMemorySpike");

        _logger.LogWarning("Starting memory spike simulation");

        var data = new List<byte[]>();
        try
        {
            for (int i = 0; i < 50; i++)
            {
                data.Add(new byte[10 * 1024 * 1024]); // 10MB each → 500MB total
            }

            activity?.SetTag("memory.allocated_mb", data.Count * 10);
            _logger.LogInformation("Allocated {Count}MB", data.Count * 10);
        }
        finally
        {
            data.Clear();
            GC.Collect();
        }

        return Ok(new
        {
            message = "Memory spike simulation completed",
            allocatedMb = 500,
            traceId = Activity.Current?.TraceId.ToString()
        });
    }

    // ── 7. Dependency Failure ───────────────────────────────────────
    [HttpGet("dependency-failure")]
    public async Task<IActionResult> DependencyFailure()
    {
        using var activity = ActivitySource.StartActivity("SimulateDependencyFailure");
        activity?.SetTag("dependency.url", "http://unreachable-service.local:9999/api/data");

        _logger.LogWarning("Calling unreachable dependency");

        try
        {
            var client = _httpClientFactory.CreateClient();
            client.Timeout = TimeSpan.FromSeconds(5);
            var response = await client.GetAsync("http://unreachable-service.local:9999/api/data");
            return Ok(); // never reached
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
            _logger.LogError(ex, "Dependency call failed");

            return StatusCode(502, new
            {
                error = "DependencyFailure",
                message = ex.Message,
                traceId = Activity.Current?.TraceId.ToString()
            });
        }
    }

    // ── 8. Serialization Error ──────────────────────────────────────
    [HttpGet("serialization-error")]
    public IActionResult SerializationError()
    {
        using var activity = ActivitySource.StartActivity("SimulateSerializationError");

        _logger.LogWarning("Triggering serialization error with circular reference");

        try
        {
            var a = new CircularRef { Name = "A" };
            var b = new CircularRef { Name = "B", Ref = a };
            a.Ref = b;

            // This will throw due to circular reference
            var json = JsonSerializer.Serialize(a);
            return Ok(json); // never reached
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
            _logger.LogError(ex, "Serialization failed");

            return StatusCode(500, new
            {
                error = "SerializationError",
                message = ex.Message,
                traceId = Activity.Current?.TraceId.ToString()
            });
        }
    }

    // ── 9. Auth Failure (401) ───────────────────────────────────────
    [HttpGet("auth-failure")]
    public IActionResult AuthFailure()
    {
        using var activity = ActivitySource.StartActivity("SimulateAuthFailure");
        activity?.SetTag("auth.type", "Bearer");
        activity?.SetStatus(ActivityStatusCode.Error, "Unauthorized");

        _logger.LogWarning("Simulating authentication failure (401)");

        return Unauthorized(new
        {
            error = "Unauthorized",
            message = "Invalid or missing authentication token",
            traceId = Activity.Current?.TraceId.ToString()
        });
    }

    // ── 10. Forbidden (403) ─────────────────────────────────────────
    [HttpGet("forbidden")]
    public IActionResult Forbidden()
    {
        using var activity = ActivitySource.StartActivity("SimulateForbidden");
        activity?.SetTag("auth.type", "Bearer");
        activity?.SetTag("auth.required_role", "Admin");
        activity?.SetStatus(ActivityStatusCode.Error, "Forbidden");

        _logger.LogWarning("Simulating authorization failure (403)");

        return StatusCode(403, new
        {
            error = "Forbidden",
            message = "You do not have permission to access this resource. Required role: Admin",
            traceId = Activity.Current?.TraceId.ToString()
        });
    }

    // ── 11. Slow Response ───────────────────────────────────────────
    [HttpGet("slow-response")]
    public async Task<IActionResult> SlowResponse()
    {
        using var activity = ActivitySource.StartActivity("SimulateSlowResponse");
        activity?.SetTag("delay.duration_ms", 5000);

        _logger.LogInformation("Starting slow response (5-second delay)");

        await Task.Delay(5000);

        _logger.LogInformation("Slow response completed");

        return Ok(new
        {
            message = "Slow response completed after 5 seconds",
            delayMs = 5000,
            traceId = Activity.Current?.TraceId.ToString()
        });
    }

    // ── 12. Complex Business Error ──────────────────────────────────
    [HttpGet("complex-business-error")]
    public IActionResult ComplexBusinessError()
    {
        using var activity = ActivitySource.StartActivity("SimulateComplexBusinessError");

        _logger.LogWarning("Triggering complex business error (OrderService -> PaymentGateway)");

        try
        {
            var orderService = new OrderService();
            // Invalid business logic: applying a discount greater than the price
            orderService.ProcessOrder(price: 100, discount: 150);
            return Ok(); // never reached
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
            _logger.LogError(ex, "Complex business error occurred");

            return StatusCode(500, new
            {
                error = "ComplexBusinessError",
                message = ex.Message,
                traceId = Activity.Current?.TraceId.ToString()
            });
        }
    }

    // ── 13. Indirect Error ──────────────────────────────────────────
    // Simulated as a normal business endpoint so we can see how an error propagates 
    // across multiple layers (Controller -> Registration -> Account -> Notification -> Email)
    [HttpGet("process-registration")]
    public IActionResult ProcessRegistration()
    {
        using var activity = ActivitySource.StartActivity("ProcessRegistrationEndpoint");

        _logger.LogInformation("Starting user registration process");

        try
        {
            var registrationService = new RegistrationService();
            // We pass a bad ID (999), meaning the account is invalid/missing.
            // But a defect in the validation layer passes it down as a null object.
            registrationService.RegisterUser(999); 
            return Ok(new { message = "Registration successful" }); // never reached
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
            _logger.LogError(ex, "Registration process failed due to an error in a downstream component");

            return StatusCode(500, new
            {
                error = "ProcessRegistrationFailed",
                message = ex.Message,
                traceId = Activity.Current?.TraceId.ToString()
            });
        }
    }

    // ── 14. Rate Limit Exceeded (429) ───────────────────────────────
    [HttpGet("rate-limit")]
    public IActionResult RateLimitExceeded()
    {
        using var activity = ActivitySource.StartActivity("SimulateRateLimit");
        activity?.SetTag("http.status_code", 429);
        activity?.SetTag("rate_limit.limit", 100);
        activity?.SetTag("rate_limit.remaining", 0);
        activity?.SetTag("rate_limit.reset_time", DateTime.UtcNow.AddMinutes(1).ToString("O"));

        _logger.LogWarning("Simulating Rate Limit Exceeded (429 Too Many Requests)");

        return StatusCode(429, new
        {
            error = "TooManyRequests",
            message = "Rate limit exceeded. Try again in 60 seconds.",
            traceId = Activity.Current?.TraceId.ToString()
        });
    }

    // ── 15. Invalid Data Format / Parsing Error ─────────────────────
    [HttpGet("invalid-data-format")]
    public IActionResult InvalidDataFormat()
    {
        using var activity = ActivitySource.StartActivity("SimulateInvalidDataFormat");
        
        _logger.LogWarning("Triggering invalid data format exception (simulated corrupt DB record)");

        try
        {
            // Simulate reading a corrupted JSON string from a database or cache
            string badData = "{\"userId\": 123, \"isActive\": \"not_a_boolean\"}";
            var parsed = JsonSerializer.Deserialize<Dictionary<string, bool>>(badData);
            
            return Ok(parsed); // never reached
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
            _logger.LogError(ex, "Failed to parse data format");

            return StatusCode(500, new
            {
                error = "DataParsingError",
                message = "Failed to parse incoming data: " + ex.Message,
                traceId = Activity.Current?.TraceId.ToString()
            });
        }
    }

    // ── 16. Partial Saga Failure (Distributed Transaction) ──────────
    [HttpGet("partial-saga-failure")]
    public IActionResult PartialSagaFailure()
    {
        using var activity = ActivitySource.StartActivity("SimulatePartialSagaFailure");

        _logger.LogWarning("Triggering distributed transaction / partial saga failure");

        try
        {
            var inventoryService = new LocalInventoryService();
            var billingService = new RemoteBillingService();

            // Step 1: Deduct from local inventory (Success)
            inventoryService.ReserveItem("SKU-9999", 1);

            // Step 2: Call remote billing service (Fails)
            billingService.ChargeCustomer("CUST-123", 49.99m);

            return Ok(new { message = "Order fulfilled successfully" }); // never reached
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
            _logger.LogError(ex, "Saga failed at billing step. Inventory is now out of sync (not compensated)!");

            return StatusCode(500, new
            {
                error = "SagaFailure",
                message = "The transaction partially failed. Data inconsistency detected: " + ex.Message,
                traceId = Activity.Current?.TraceId.ToString()
            });
        }
    }

    // ── Helper class for circular reference ─────────────────────────
    private class CircularRef
    {
        public string Name { get; set; } = "";
        public CircularRef? Ref { get; set; }
    }

    // ── Helper classes for complex business error ───────────────────
    private class OrderService
    {
        private readonly PaymentGateway _paymentGateway = new();

        public void ProcessOrder(decimal price, decimal discount)
        {
            using var activity = ErrorSimulationController.ActivitySource.StartActivity("OrderService.ProcessOrder");
            activity?.SetTag("order.price", price);
            activity?.SetTag("order.discount", discount);

            // Bug in business logic: discount can make finalPrice negative
            decimal finalPrice = price - discount;

            activity?.SetTag("order.final_price", finalPrice);

            _paymentGateway.Charge(finalPrice);
        }
    }

    private class PaymentGateway
    {
        public void Charge(decimal amount)
        {
            using var activity = ErrorSimulationController.ActivitySource.StartActivity("PaymentGateway.Charge");
            activity?.SetTag("payment.amount", amount);

            if (amount <= 0)
            {
                throw new ArgumentException($"Invalid payment amount: {amount}. Amount must be greater than zero.", nameof(amount));
            }

            // Simulate successful charge
        }
    }

    // ── Helper classes for indirect error (User Registration) ───────
    private class RegistrationService
    {
        private readonly AccountValidator _validator = new();

        public void RegisterUser(int accountId)
        {
            using var activity = ErrorSimulationController.ActivitySource.StartActivity("RegistrationService.RegisterUser");
            activity?.SetTag("account.id", accountId);

            _validator.ValidateAndNotify(accountId);
        }
    }

    private class AccountValidator
    {
        private readonly NotificationService _notificationService = new();

        public void ValidateAndNotify(int accountId)
        {
            using var activity = ErrorSimulationController.ActivitySource.StartActivity("AccountValidator.ValidateAndNotify");
            
            // Simulate fetching account details. Returns null for 999
            UserProfile? profile = accountId == 999 ? null : new UserProfile { Id = accountId, Email = "newuser@example.com" };

            // Defect: Validation layer forgets to check for null profile before proceeding
            activity?.SetTag("profile.status", profile == null ? "invalid" : "valid");

            _notificationService.QueueWelcomeEmail(profile!);
        }
    }

    private class NotificationService
    {
        private readonly EmailSender _emailSender = new();

        public void QueueWelcomeEmail(UserProfile profile)
        {
            using var activity = ErrorSimulationController.ActivitySource.StartActivity("NotificationService.QueueWelcomeEmail");
            
            // Still no null check here, just passing it deeper
            _emailSender.SendHtmlEmail(profile);
        }
    }

    private class EmailSender
    {
        public void SendHtmlEmail(UserProfile profile)
        {
            using var activity = ErrorSimulationController.ActivitySource.StartActivity("EmailSender.SendHtmlEmail");
            
            // Defect finally manifests here, deep in the call stack
            activity?.SetTag("email.recipient", profile.Email); // Throws NullReferenceException because profile is null

            // Code to send the email would go here
        }
    }

    private class UserProfile 
    {
        public int Id { get; set; }
        public string Email { get; set; } = "";
    }

    // ── Helper classes for Saga Failure ─────────────────────────────
    private class LocalInventoryService
    {
        public void ReserveItem(string sku, int quantity)
        {
            using var activity = ErrorSimulationController.ActivitySource.StartActivity("InventoryService.ReserveItem");
            activity?.SetTag("inventory.sku", sku);
            activity?.SetTag("inventory.quantity", quantity);
            
            // Succeeds and commits to hypothetical database
            activity?.AddEvent(new ActivityEvent("Inventory reserved successfully"));
        }
    }

    private class RemoteBillingService
    {
        public void ChargeCustomer(string customerId, decimal amount)
        {
            using var activity = ErrorSimulationController.ActivitySource.StartActivity("BillingService.ChargeCustomer");
            activity?.SetTag("billing.customer", customerId);
            activity?.SetTag("billing.amount", amount);

            // Simulates a transient network failure or payment gateway rejection
            throw new HttpRequestException("Payment gateway timed out. Charge failed.");
        }
    }
}


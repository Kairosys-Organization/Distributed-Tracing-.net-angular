using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using PathfinderApi.Models;

namespace PathfinderApi.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class UsersController : ControllerBase
    {
        private readonly AppDbContext _context;
        private readonly ILogger<UsersController> _logger;

        public UsersController(AppDbContext context, ILogger<UsersController> logger)
        {
            _context = context;
            _logger = logger;
        }

        [HttpGet]
        public async Task<IActionResult> GetUsers()
        {
            var users = await _context.Users.ToListAsync();
            return Ok(users);
        }

        [HttpPost("simulate-duplicate")]
        public async Task<IActionResult> SimulateDuplicateUser()
        {
            _logger.LogInformation("Attempting to insert a duplicate user to simulate a constraint violation.");
            
            // Try to add the user that is seeded on startup (john@example.com)
            var duplicateUser = new User 
            { 
                Email = "john@example.com", 
                FullName = "John Clone" 
            };

            _context.Users.Add(duplicateUser);
            
            // This will deliberately throw a DbUpdateException because of the unique index
            await _context.SaveChangesAsync();
            
            return Ok(duplicateUser);
        }

        [HttpPost("simulate-timeout")]
        public async Task<IActionResult> SimulateTimeout()
        {
            _logger.LogWarning("Simulating a sluggish database connection or network timeout...");
            
            // Artificial delay to make traces show a long processing time before failing
            await Task.Delay(3000);
            
            // Throwing a TaskCanceledException to simulate the request dropping
            throw new TaskCanceledException("The database query timed out after 3000ms.");
        }

        [HttpPost("simulate-null-reference")]
        public IActionResult SimulateNullReference()
        {
            _logger.LogError("Simulating an unexpected null reference in business logic...");
            
            User user = null;
            // Deliberately triggering a NullReferenceException
            var nameLength = user.FullName.Length;
            
            return Ok();
        }
    }
}

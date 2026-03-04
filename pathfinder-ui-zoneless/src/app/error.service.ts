import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';

const API_BASE = (window as any).env?.API_URL || 'http://localhost:5215/api';

@Injectable({
    providedIn: 'root',
})
export class ErrorService {
    constructor(private http: HttpClient) { }

    // ── Server-side error triggers ─────────────────────────────────

    healthCheck(): Observable<any> {
        return this.http.get(`${API_BASE}/health`);
    }

    unhandledException(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/unhandled-exception`);
    }

    handledException(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/handled-exception`);
    }

    sqlError(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/sql-error`);
    }

    timeout(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/timeout`);
    }

    cpuSpike(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/cpu-spike`);
    }

    memorySpike(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/memory-spike`);
    }

    dependencyFailure(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/dependency-failure`);
    }

    serializationError(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/serialization-error`);
    }

    authFailure(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/auth-failure`);
    }

    forbidden(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/forbidden`);
    }

    slowResponse(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/slow-response`);
    }

    complexBusinessError(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/complex-business-error`);
    }

    processRegistration(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/process-registration`);
    }

    rateLimitExceeded(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/rate-limit`);
    }

    invalidDataFormat(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/invalid-data-format`);
    }

    partialSagaFailure(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/partial-saga-failure`);
    }

    simulateNewAppHttpError(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/ui-pathfinderapi-newapp`);
    }

    simulateNewAppRabbitMqError(): Observable<any> {
        return this.http.get(`${API_BASE}/errors/rabbitmq-newapp`);
    }

    // ── Database Real-Life Errors (via UsersController) ──────────────────────────────
    simulateDuplicateUser(): Observable<any> {
        return this.http.post(`${API_BASE}/users/simulate-duplicate`, {});
    }

    simulateDbTimeout(): Observable<any> {
        return this.http.post(`${API_BASE}/users/simulate-timeout`, {});
    }

    simulateNullReference(): Observable<any> {
        return this.http.post(`${API_BASE}/users/simulate-null-reference`, {});
    }

    // No manual span creation — GlobalErrorHandler traces everything automatically

    simulateJsException(): void {
        const obj: any = undefined;
        obj.property; // TypeError — caught by GlobalErrorHandler → Jaeger + console
    }

    simulatePromiseRejection(): void {
        // Real unhandled rejection — caught by window listener → Jaeger + console
        Promise.reject(new Error('Simulated unhandled promise rejection'));
    }

    simulateNetworkFailure(): Observable<any> {
        // HTTP error — auto-instrumented by OTel fetch/XHR → Jaeger + console
        return this.http.get('http://localhost:9999/does-not-exist');
    }

    simulateCorsFailure(): Observable<any> {
        // CORS error — auto-instrumented by OTel fetch/XHR → Jaeger + console
        return this.http.get('https://www.google.com/');
    }

    simulateJsonParseError(): void {
        // SyntaxError — caught by GlobalErrorHandler → Jaeger + console
        JSON.parse('{invalid json!!!}');
    }

    simulateResourceLoadFailure(): void {
        // Resource error — caught by window error listener → Jaeger + console
        const img = new Image();
        img.src = 'http://localhost:9999/nonexistent-image.png';
        document.body.appendChild(img);
    }

    simulateUiFreeze(): void {
        const start = Date.now();
        while (Date.now() - start < 3000) {
            // Busy wait to freeze the main thread for 3 seconds
        }
        throw new Error('Application unresponsive: Main thread blocked for 3000ms');
    }

    simulateMaxCallStackSizeExceeded(): void {
        const recurse = (): any => recurse();
        recurse();
    }
}

import { Component, ChangeDetectorRef } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ErrorService } from './error.service';

interface ActionButton {
  id: string;
  label: string;
  description: string;
  icon: string;
  type: 'client' | 'server';
  status: 'idle' | 'loading' | 'success' | 'error';
  response?: string;
  action: () => void;
}

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [CommonModule],
  templateUrl: './app.component.html',
  styleUrl: './app.component.scss',
})
export class AppComponent {
  constructor(
    private errorService: ErrorService,
    private cdr: ChangeDetectorRef
  ) { }

  clientActions: ActionButton[] = [
    {
      id: 'js-exception',
      label: 'JS Exception',
      description: 'TypeError: cannot read property of undefined',
      icon: '💥',
      type: 'client',
      status: 'idle',
      action: () => this.runClient('js-exception', () => this.errorService.simulateJsException()),
    },
    {
      id: 'promise-rejection',
      label: 'Promise Rejection',
      description: 'Unhandled async rejection',
      icon: '⚡',
      type: 'client',
      status: 'idle',
      action: () => this.runClient('promise-rejection', () => this.errorService.simulatePromiseRejection()),
    },
    {
      id: 'network-failure',
      label: 'Network Failure',
      description: 'Connection to unreachable host',
      icon: '🔌',
      type: 'client',
      status: 'idle',
      action: () =>
        this.runHttp('network-failure', this.errorService.simulateNetworkFailure()),
    },
    {
      id: 'cors-failure',
      label: 'CORS Failure',
      description: 'Cross-origin request blocked',
      icon: '🚫',
      type: 'client',
      status: 'idle',
      action: () =>
        this.runHttp('cors-failure', this.errorService.simulateCorsFailure()),
    },
    {
      id: 'json-parse',
      label: 'JSON Parse Error',
      description: 'Invalid JSON string parsing',
      icon: '📄',
      type: 'client',
      status: 'idle',
      action: () => this.runClient('json-parse', () => this.errorService.simulateJsonParseError()),
    },
    {
      id: 'resource-load',
      label: 'Resource Load Failure',
      description: 'Image from unreachable server',
      icon: '🖼️',
      type: 'client',
      status: 'idle',
      action: () => this.runClient('resource-load', () => this.errorService.simulateResourceLoadFailure()),
    },
    {
      id: 'ui-freeze',
      label: 'UI Freeze (3s)',
      description: 'Synchronous blocking computation',
      icon: '❄️',
      type: 'client',
      status: 'idle',
      action: () => this.runClient('ui-freeze', () => this.errorService.simulateUiFreeze()),
    },
    {
      id: 'stack-overflow',
      label: 'Stack Overflow',
      description: 'Maximum call stack size exceeded',
      icon: '🥞',
      type: 'client',
      status: 'idle',
      action: () => this.runClient('stack-overflow', () => this.errorService.simulateMaxCallStackSizeExceeded()),
    },
  ];

  serverActions: ActionButton[] = [
    {
      id: 'health',
      label: 'Health Check',
      description: 'Verify end-to-end trace (200 OK)',
      icon: '💚',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('health', this.errorService.healthCheck()),
    },
    {
      id: 'unhandled',
      label: 'Unhandled Exception',
      description: 'NullReferenceException (500)',
      icon: '🔥',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('unhandled', this.errorService.unhandledException()),
    },
    {
      id: 'handled',
      label: 'Handled Exception',
      description: 'InvalidOperationException (500)',
      icon: '⚠️',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('handled', this.errorService.handledException()),
    },
    {
      id: 'sql',
      label: 'Database Error',
      description: 'Simulated SQL connection failure',
      icon: '🗄️',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('sql', this.errorService.sqlError()),
    },
    {
      id: 'timeout',
      label: 'Timeout',
      description: '30-second delay (exceeds client timeout)',
      icon: '⏱️',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('timeout', this.errorService.timeout()),
    },
    {
      id: 'cpu',
      label: 'CPU Spike',
      description: '3-second busy loop',
      icon: '🔄',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('cpu', this.errorService.cpuSpike()),
    },
    {
      id: 'memory',
      label: 'Memory Spike',
      description: 'Allocate 500MB temporarily',
      icon: '📈',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('memory', this.errorService.memorySpike()),
    },
    {
      id: 'dependency',
      label: 'Dependency Failure',
      description: 'HTTP call to unreachable service',
      icon: '🔗',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('dependency', this.errorService.dependencyFailure()),
    },
    {
      id: 'serialization',
      label: 'Serialization Error',
      description: 'Circular reference in JSON',
      icon: '🔁',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('serialization', this.errorService.serializationError()),
    },
    {
      id: 'auth',
      label: 'Auth Failure (401)',
      description: 'Missing/invalid token',
      icon: '🔒',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('auth', this.errorService.authFailure()),
    },
    {
      id: 'forbidden',
      label: 'Forbidden (403)',
      description: 'Insufficient permissions',
      icon: '🛡️',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('forbidden', this.errorService.forbidden()),
    },
    {
      id: 'biz-null',
      label: 'Business Logic Null',
      description: 'Unexpected Null Reference on User',
      icon: '🕳️',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('biz-null', this.errorService.simulateNullReference()),
    },
    {
      id: 'complex-biz',
      label: 'Complex Business Error',
      description: 'Payment logic fault from bad inputs',
      icon: '🧩',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('complex-biz', this.errorService.complexBusinessError()),
    },
    {
      id: 'process-registration',
      label: 'Indirect Error',
      description: 'Root cause tracking across 4 nested layers',
      icon: '🕵️',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('process-registration', this.errorService.processRegistration()),
    },
    {
      id: 'slow',
      label: 'Slow Response',
      description: '5-second delay then 200 OK',
      icon: '🐌',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('slow', this.errorService.slowResponse()),
    },
    {
      id: 'rate-limit',
      label: 'Rate Limit Exceeded',
      description: '429 Too Many Requests',
      icon: '🚦',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('rate-limit', this.errorService.rateLimitExceeded()),
    },
    {
      id: 'invalid-data-format',
      label: 'Invalid Data Format',
      description: 'JSON parsing failure from corrupt data',
      icon: '🗑️',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('invalid-data-format', this.errorService.invalidDataFormat()),
    },
    {
      id: 'partial-saga-failure',
      label: 'Partial Saga Failure',
      description: 'Distributed transaction inconsistency',
      icon: '⛓️',
      type: 'server',
      status: 'idle',
      action: () => this.runHttp('partial-saga-failure', this.errorService.partialSagaFailure()),
    },
  ];

  private findButton(id: string): ActionButton | undefined {
    return (
      this.clientActions.find((a) => a.id === id) ||
      this.serverActions.find((a) => a.id === id)
    );
  }

  private setStatus(id: string, status: ActionButton['status'], response?: string) {
    const btn = this.findButton(id);
    if (btn) {
      btn.status = status;
      btn.response = response;
      this.cdr.detectChanges(); // Force UI update (Zoneless fix)
    }
  }

  private runClient(id: string, fn: () => void) {
    this.setStatus(id, 'loading');
    try {
      fn();
      // For sync calls that don't throw (like Promise triggers), set 'error' (check Jaeger) 
      // because we expect them to trigger an error background process
      this.setStatus(id, 'error', 'Exception thrown (check Jaeger)');
    } catch (e: any) {
      this.setStatus(id, 'error', e.message);
      throw e; // Propagate to GlobalErrorHandler
    }
  }

  private runHttp(id: string, obs: import('rxjs').Observable<any>) {
    this.setStatus(id, 'loading');
    obs.subscribe({
      next: (res) => {
        const traceId = res?.traceId || '';
        this.setStatus(id, 'success', traceId ? `TraceId: ${traceId}` : JSON.stringify(res).substring(0, 100));
      },
      error: (err) => {
        const msg = err?.error?.message || err?.message || 'Request failed';
        const traceId = err?.error?.traceId || '';
        this.setStatus(id, 'error', traceId ? `${msg} | TraceId: ${traceId}` : msg);
      },
    });
  }

  openJaeger() {
    window.open('http://localhost:16686', '_blank');
  }
}

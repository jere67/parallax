// The root shell for Parallax on a phone. scripts/setup.sh copies it over the one Jac scaffolds,
// whose white safe area and dark status bar text do not suit a dark app.
import React from 'react';
import { StatusBar } from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import {
  JacClientErrorBoundary,
  ErrorFallback,
  __jacReactErrorHandler,
  __jacInstallErrorHandlers,
// @ts-expect-error - Jac runtime has no .d.ts yet
} from '@jac/runtime';
// @ts-expect-error - Jac compiled bundle has no .d.ts.
import { app as JacApp } from '../jac-app';

__jacInstallErrorHandlers();

export default function App() {
  return (
    <JacClientErrorBoundary FallbackComponent={ErrorFallback} onError={__jacReactErrorHandler}>
      <SafeAreaProvider>
        <SafeAreaView style={{ flex: 1, backgroundColor: '#0c0b09' }}>
          <StatusBar barStyle="light-content" backgroundColor="#0c0b09" />
          <JacApp />
        </SafeAreaView>
      </SafeAreaProvider>
    </JacClientErrorBoundary>
  );
}

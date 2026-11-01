import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import './brand.css';
import './styles.css';
import { applyTheme, followSystemTheme, savedTheme } from './theme';
applyTheme(savedTheme());
// Onboarding and the startup screen have no Appearance control, so the app follows macOS here.
followSystemTheme();
createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);

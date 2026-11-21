import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import './brand.css';
import './styles.css';
import { applyTheme, savedTheme } from './theme';
applyTheme(savedTheme());
createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);

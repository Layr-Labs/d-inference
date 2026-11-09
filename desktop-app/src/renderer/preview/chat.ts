import type { ChatAPI } from '../../shared/chat';
import type { FeaturePreview } from './types';

// Development preview of chat: a simulated local API that streams canned answers.
export const chatPreview: FeaturePreview = {};

export const previewChatAPI: ChatAPI = {
  async chatModels() {
    return { models: [], error: 'Chat preview is not built yet.', code: 'unavailable' };
  },
  async chatSend() {
    throw new Error('Chat preview is not built yet.');
  },
  async chatCancel() {},
  onChat() {
    return () => {};
  },
};

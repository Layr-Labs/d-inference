"use client";

import { useState, useRef, useCallback, useEffect } from "react";
import { trackEvent } from "@/lib/google-analytics";
import {
  validateImageFile,
  fileToDataURL,
  MAX_IMAGES_PER_MESSAGE,
} from "@/lib/image-upload";

export interface ImageUpload {
  images: string[];
  imgError: string | null;
  atLimit: boolean;
  fileInputRef: React.RefObject<HTMLInputElement | null>;
  addFiles: (files: File[]) => Promise<void>;
  removeImage: (index: number) => void;
  clearImages: () => void;
  handlePaste: (e: React.ClipboardEvent) => void;
  handleFileInputChange: (e: React.ChangeEvent<HTMLInputElement>) => void;
}

/**
 * Image-attachment state for the chat composer: staging, validation, base64
 * encoding, paste + file-picker intake, and the per-message cap. `enabled`
 * gates intake (pass false for non-vision models); when it flips false any
 * staged images are auto-cleared so we never send media a model can't accept.
 */
export function useImageUpload(enabled: boolean): ImageUpload {
  const [images, setImages] = useState<string[]>([]);
  const [imgError, setImgError] = useState<string | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!enabled && images.length > 0) {
      setImages([]);
      setImgError(null);
    }
  }, [enabled, images.length]);

  const addFiles = useCallback(
    async (files: File[]) => {
      if (!enabled || files.length === 0) return;
      setImgError(null);
      let remaining = MAX_IMAGES_PER_MESSAGE - images.length;
      if (remaining <= 0) {
        setImgError(`You can attach up to ${MAX_IMAGES_PER_MESSAGE} images per message.`);
        return;
      }
      const accepted: string[] = [];
      for (const file of files) {
        if (remaining <= 0) {
          setImgError(`You can attach up to ${MAX_IMAGES_PER_MESSAGE} images per message.`);
          break;
        }
        const err = validateImageFile(file);
        if (err) {
          setImgError(err);
          continue;
        }
        try {
          accepted.push(await fileToDataURL(file));
          remaining -= 1;
        } catch {
          setImgError("Failed to read one of the images. Try again.");
        }
      }
      if (accepted.length > 0) {
        // Cap inside the updater: two overlapping intakes (e.g. a paste landing
        // while a prior file read is still awaiting) both read the same stale
        // `images.length` above, so enforce the limit against the latest state.
        setImages((prev) => [...prev, ...accepted].slice(0, MAX_IMAGES_PER_MESSAGE));
        trackEvent("chat_image_attached", { count: accepted.length });
      }
    },
    [enabled, images.length]
  );

  const removeImage = useCallback((index: number) => {
    setImages((prev) => prev.filter((_, i) => i !== index));
  }, []);

  const clearImages = useCallback(() => {
    setImages([]);
    setImgError(null);
  }, []);

  const handlePaste = useCallback(
    (e: React.ClipboardEvent) => {
      if (!enabled) return;
      const files = Array.from(e.clipboardData.files).filter((f) =>
        f.type.startsWith("image/")
      );
      if (files.length > 0) {
        e.preventDefault();
        void addFiles(files);
      }
    },
    [enabled, addFiles]
  );

  const handleFileInputChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const files = e.target.files ? Array.from(e.target.files) : [];
      void addFiles(files);
      // Reset so picking the same file again still fires onChange.
      e.target.value = "";
    },
    [addFiles]
  );

  return {
    images,
    imgError,
    atLimit: images.length >= MAX_IMAGES_PER_MESSAGE,
    fileInputRef,
    addFiles,
    removeImage,
    clearImages,
    handlePaste,
    handleFileInputChange,
  };
}

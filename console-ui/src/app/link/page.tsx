"use client";

import { DeviceLinkForm } from "./DeviceLinkForm";

export default function LinkPage() {
  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-50 to-indigo-50 flex items-center justify-center p-4">
      <div className="w-full max-w-md">
        <div className="text-center mb-8">
          <h1 className="text-2xl font-bold text-slate-900">
            Link Your Device
          </h1>
          <p className="text-slate-500 mt-2">
            Connect your Mac to your EigenInference account to receive
            earnings for providing compute.
          </p>
        </div>
        <DeviceLinkForm />
      </div>
    </div>
  );
}

export function ModelGlyph({ name }: { name: string }) {
  return (
    <div className="model-glyph">
      {name.startsWith('GPT') ? '◎' : name.startsWith('Gemma') ? '✧' : 'Q'}
    </div>
  );
}

from pathlib import Path
base=Path('/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915')
assert base.resolve()==base and base.is_dir()
(base/'supervisor').mkdir(mode=0o700)
(base/'runs').mkdir(mode=0o700,exist_ok=True)
assert (base/'runs').resolve()==base/'runs'
assert not (base/'runs/short-27b-1').exists()
print('Created new supervisor; fresh run absent')

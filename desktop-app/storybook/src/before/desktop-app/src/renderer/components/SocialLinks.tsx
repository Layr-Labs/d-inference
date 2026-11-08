import { api, isPreview } from '../useBackend';
import { socialLinks } from '../../shared/socialLinks';
import { GithubIcon, SlackIcon, XIcon } from './BrandIcons';

export function SocialLinks() {
  return (
    <div className="social-links" role="group" aria-label="Community">
      {(
        [
          { id: 'slack', label: 'Join the Darkbloom Slack', Icon: SlackIcon },
          { id: 'github', label: 'Darkbloom on GitHub', Icon: GithubIcon },
          { id: 'x', label: 'Darkbloom on X', Icon: XIcon },
        ] as const
      ).map(({ id, label, Icon }) => (
        <a
          key={id}
          href={socialLinks[id]}
          title={label}
          aria-label={label}
          target="_blank"
          rel="noopener noreferrer"
          onClick={(event) => {
            if (!isPreview) {
              event.preventDefault();
              void api?.openExternal(id);
            }
          }}
        >
          <Icon size={17} />
        </a>
      ))}
    </div>
  );
}

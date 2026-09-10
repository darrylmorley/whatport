// The native disclosure works without JavaScript. This adds convenient dismissal.
(() => {
  const menu = document.querySelector('[data-mobile-nav]');
  if (!menu) return;
  const trigger = menu.querySelector('summary');
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && menu.open) {
      menu.open = false;
      trigger.focus();
    }
  });
  document.addEventListener('click', event => {
    if (!menu.open) return;
    const link = event.target.closest('a');
    if (!menu.contains(event.target) || link) menu.open = false;
    if (link && menu.contains(link)) {
      const target = new URL(link.href);
      if (target.origin === location.origin && target.pathname === location.pathname && target.hash) {
        const section = document.getElementById(target.hash.slice(1));
        if (section) {
          section.tabIndex = -1;
          section.focus({ preventScroll: true });
        }
      }
    }
  });
  document.addEventListener('focusin', event => {
    if (!menu.contains(event.target)) menu.open = false;
  });
  matchMedia('(min-width: 981px)').addEventListener('change', event => {
    if (event.matches) menu.open = false;
  });
})();

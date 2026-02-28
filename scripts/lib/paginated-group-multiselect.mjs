import { AutocompletePrompt, MultiSelectPrompt } from '@clack/core';
import pc from 'picocolors';
import {
  S_BAR, S_BAR_END,
  symbol as stepSymbol,
} from '@clack/prompts';

const SYM = { UNSELECTED: '○', SELECTED: '●', LOCKED: '✓', CURSOR: '❯' };

function renderOption(option, isActive, selectedValues) {
  const label = option.label ?? String(option.value);
  const isSelected = selectedValues.includes(option.value);
  const hint = option.hint ? ` ${pc.dim(`(${option.hint})`)}` : '';

  if (option.disabled) {
    return `  ${pc.gray(SYM.UNSELECTED)} ${pc.strikethrough(pc.gray(label))}`;
  }

  const prefix = isActive ? `${pc.cyan(SYM.CURSOR)} ` : '  ';
  const icon = isSelected
    ? pc.green(SYM.SELECTED)
    : isActive ? pc.cyan(SYM.UNSELECTED) : pc.dim(SYM.UNSELECTED);
  const parenIdx = label.lastIndexOf(' (');
  const name = parenIdx > 0 ? label.slice(0, parenIdx) : label;
  const pathHint = parenIdx > 0 ? ` ${pc.dim(label.slice(parenIdx + 1))}` : '';
  const text = isActive
    ? `${pc.underline(name)}${pathHint}${hint}`
    : `${name}${pathHint}${hint}`;
  return `${prefix}${icon} ${text}`;
}

function paginate(options, cursor, maxItems, styleFn) {
  const total = options.length;
  if (total === 0) return { lines: [], footer: '' };
  if (total <= maxItems) {
    return { lines: options.map((o, i) => styleFn(o, i === cursor)), footer: '' };
  }
  let start = Math.max(0, cursor - Math.floor(maxItems / 2));
  let end = Math.min(total, start + maxItems);
  if (end - start < maxItems) start = Math.max(0, end - maxItems);

  const above = start;
  const below = total - end;
  const lines = [];
  for (let i = start; i < end; i++) {
    lines.push(styleFn(options[i], i === cursor));
  }
  const parts = [];
  if (above > 0) parts.push(`↑ ${above} more`);
  if (below > 0) parts.push(`↓ ${below} more`);
  return { lines, footer: parts.length ? pc.dim(parts.join('  ')) : '' };
}

function formatSelected(labels) {
  if (labels.length === 0) return '';
  const shown = labels.slice(0, 3).join(', ');
  const more = labels.length > 3 ? ` +${labels.length - 3} more` : '';
  return `${shown}${more}`;
}

export function paginatedGroupMultiselect(opts) {
  const { maxItems = 10, lockedGroups = {} } = opts;

  const lockedLines = [];
  const lockedLabels = [];
  for (const [groupLabel, items] of Object.entries(lockedGroups)) {
    const rule = `── ${groupLabel} ${'─'.repeat(Math.max(2, 50 - groupLabel.length))}`;
    lockedLines.push(pc.dim(rule));
    for (const item of items) {
      lockedLines.push(`  ${pc.green(SYM.LOCKED)} ${pc.dim(item.label)}`);
      lockedLabels.push(item.label);
    }
  }

  const groupHeaders = Object.keys(opts.options);
  const flatOptions = Object.values(opts.options).flat();

  const prompt = new AutocompletePrompt({
    options: flatOptions,
    multiple: true,
    initialValue: opts.initialValues ?? [],
    filter: opts.filter,
    validate: () => {
      if (opts.required && prompt.selectedValues.length === 0) {
        return 'Please select at least one option.';
      }
    },
    render() {
      const title = `${pc.gray(S_BAR)}\n${stepSymbol(this.state)}  ${opts.message}\n`;
      const bar = this.state === 'error' ? pc.yellow : pc.cyan;

      const userLabels = this.selectedValues.map(v => {
        const o = this.options.find(opt => opt.value === v);
        return o ? (o.label ?? String(o.value)) : String(v);
      });
      const allLabels = [...lockedLabels, ...userLabels];

      switch (this.state) {
        case 'submit': {
          const display = allLabels.length > 0
            ? pc.dim(formatSelected(allLabels))
            : pc.dim('none');
          return `${title}${pc.gray(S_BAR)}  ${display}`;
        }
        case 'cancel': {
          return `${title}${pc.gray(S_BAR)}  ${pc.strikethrough(pc.dim(this.userInput))}`;
        }
        default: {
          const B = (s) => `${bar(S_BAR)}${s ? `  ${s}` : ''}`;
          const userInput = this.userInput;

          const searchText = userInput
            ? this.isNavigating ? pc.dim(userInput) : this.userInputWithCursor
            : '';
          const matchCount = this.filteredOptions.length !== this.options.length
            ? pc.dim(` (${this.filteredOptions.length} match${this.filteredOptions.length === 1 ? '' : 'es'})`)
            : '';

          // Header: title → locked → group header → search → kbd → empty line
          const lines = [...`${title}${B()}`.split('\n')];

          if (lockedLines.length) {
            for (const l of lockedLines) lines.push(B(l));
            lines.push(B());
          }

          if (groupHeaders.length > 0) {
            const rule = `── ${groupHeaders[0]} ${'─'.repeat(Math.max(2, 50 - groupHeaders[0].length))}`;
            lines.push(B(pc.dim(rule)));
          }

          lines.push(B(`${pc.dim('Search:')} ${searchText}${matchCount}`));
          lines.push(B(pc.dim('↑↓ move, space select, enter confirm')));

          if (this.filteredOptions.length === 0 && userInput) {
            lines.push(B(pc.yellow('No matches found')));
          }
          if (this.state === 'error') {
            lines.push(B(pc.yellow(this.error)));
          }

          lines.push(B());

          const { lines: optLines, footer } = paginate(
            this.filteredOptions, this.cursor, maxItems,
            (o, active) => renderOption(o, active, this.selectedValues),
          );
          for (const l of optLines) lines.push(`${bar(S_BAR)} ${l}`);
          if (footer) lines.push(B(footer));

          // Footer: empty line → selected → bar end
          if (allLabels.length > 0) {
            lines.push(B());
            lines.push(B(pc.green('Selected: ') + formatSelected(allLabels)));
          }

          lines.push(`${bar(S_BAR_END)}`);
          return lines.join('\n');
        }
      }
    },
  });

  return prompt.prompt();
}

export function styledMultiselect(opts) {
  const required = opts.required ?? true;

  return new MultiSelectPrompt({
    options: opts.options,
    initialValues: opts.initialValues ?? [],
    required,
    cursorAt: opts.cursorAt,
    validate(value) {
      if (required && (!value || value.length === 0)) {
        return `Please select at least one option.\n${pc.reset(pc.dim(
          `Press ${pc.gray(pc.bgWhite(pc.inverse(' space ')))} to select, ${pc.gray(pc.bgWhite(pc.inverse(' enter ')))} to submit`
        ))}`;
      }
    },
    render() {
      const title = `${pc.gray(S_BAR)}\n${stepSymbol(this.state)}  ${opts.message}\n`;
      const selected = this.value ?? [];

      switch (this.state) {
        case 'submit': {
          const items = this.options
            .filter(o => selected.includes(o.value))
            .map(o => pc.dim(o.label ?? String(o.value)));
          return `${title}${pc.gray(S_BAR)}  ${items.join(pc.dim(', ')) || pc.dim('none')}`;
        }
        case 'cancel': {
          const items = this.options
            .filter(o => selected.includes(o.value))
            .map(o => pc.strikethrough(pc.dim(o.label ?? String(o.value))));
          return `${title}${pc.gray(S_BAR)}  ${items.join(pc.dim(', '))}`;
        }
        case 'error': {
          const errLines = this.error
            .split('\n')
            .map((l, i) => i === 0 ? `${pc.yellow(S_BAR_END)}  ${pc.yellow(l)}` : `   ${l}`)
            .join('\n');
          const lines = this.options.map((o, i) =>
            renderOption(o, i === this.cursor, selected));
          return `${title}${pc.yellow(S_BAR)}  ${lines.join(`\n${pc.yellow(S_BAR)}  `)}\n${errLines}\n`;
        }
        default: {
          const bar = pc.cyan(S_BAR);
          const kbd = pc.dim(`↑↓ move, space select, enter confirm`);
          const lines = this.options.map((o, i) =>
            renderOption(o, i === this.cursor, selected));
          return `${title}${bar}  ${kbd}\n${bar}\n${bar}  ${lines.join(`\n${bar}  `)}\n${pc.cyan(S_BAR_END)}\n`;
        }
      }
    },
  }).prompt();
}

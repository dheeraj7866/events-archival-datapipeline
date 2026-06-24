module.exports = {
  parser: '@typescript-eslint/parser',
  parserOptions: {
    project: 'tsconfig.json',
    tsconfigRootDir: __dirname,
    sourceType: 'module',
  },
  plugins: ['@typescript-eslint/eslint-plugin'],
  extends: [
    'plugin:@typescript-eslint/recommended',
    'plugin:@typescript-eslint/recommended-requiring-type-checking',
  ],
  root: true,
  env: {
    node: true,
    jest: true,
  },
  ignorePatterns: ['.eslintrc.js', 'dist/', 'coverage/', 'jest.config.js'],
  rules: {
    // Naming
    '@typescript-eslint/naming-convention': [
      'error',
      { selector: 'interface', format: ['PascalCase'] },
      { selector: 'typeAlias', format: ['PascalCase'] },
      { selector: 'enum', format: ['PascalCase'] },
      { selector: 'enumMember', format: ['UPPER_CASE'] },
      { selector: 'class', format: ['PascalCase'] },
    ],

    // Safety
    '@typescript-eslint/no-explicit-any': 'warn',
    '@typescript-eslint/no-unsafe-assignment': 'warn',
    '@typescript-eslint/no-unsafe-member-access': 'warn',
    '@typescript-eslint/no-unsafe-call': 'warn',
    '@typescript-eslint/no-unsafe-return': 'warn',
    '@typescript-eslint/no-floating-promises': 'error',
    '@typescript-eslint/no-misused-promises': 'error',
    '@typescript-eslint/await-thenable': 'error',
    '@typescript-eslint/require-await': 'error',

    // PII guard — prevent raw PII fields from leaking into logs or being returned
    'no-restricted-syntax': [
      'error',
      {
        selector: "MemberExpression[property.name='aadhaarNumber']",
        message: 'Full Aadhaar number must never be stored or returned. Use aadhaarLast4Hash.',
      },
      {
        selector: "MemberExpression[property.name='fullMobile']",
        message: 'Full mobile must never be logged. Use mobileHash + mobileLast4.',
      },
    ],

    // Cleanliness
    '@typescript-eslint/explicit-function-return-type': ['warn', { allowExpressions: true }],
    '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
    'no-console': 'error',
    'prefer-const': 'error',
    'eqeqeq': ['error', 'always'],
  },
};

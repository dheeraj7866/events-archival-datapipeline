module.exports = {
  moduleFileExtensions: ['js', 'json', 'ts'],
  rootDir: '.',
  testRegex: '.*\\.spec\\.ts$',
  transform: {
    '^.+\\.(t|j)s$': ['ts-jest', { tsconfig: 'tsconfig.test.json' }],
  },
  collectCoverageFrom: ['src/**/*.ts', '!src/index.ts', '!src/**/index.ts'],
  coverageDirectory: './coverage',
  testEnvironment: 'node',
};

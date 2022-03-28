Contentful Migration Strategy
-----------------------------

**UPDATE** Please consider using [deluan/contentful-migrations](https://github.com/deluan/contentful-migrate) instead, as it's more battle-tested and I don't intend to support this project.

### Motivation

I wasn't satisfied with contentful migrations. I wrote a [blog post](https://brianschiller.com/blog/2022/03/24/contentful-isnt-for-me) about it, but the quick version is that I wanted to be able to
1. Track which migrations had been applied, so they could be run in CI
2. Inspect the existing schema at the time migrations ran.

This project supports both of those goals.

### Disclaimer

I wrote this because my client was wedded to Contentful and I didn't have a say in the matter. If you need this level of control over your data migrations, you're better off using a tool built for the task. I can recommend Django, Rails, Phoenix, or Prisma as all having better database migration stories.

If you're considering using this project, you should try to use something else. I've heard Prisma is great, and has a much better migrations story. Maybe you can throw a fancy admin panel over top of it.

MIT Licensed, so NO WARRANTY OF ANY KIND, EXPRPESS OR IMPLIED.

### Installation

1. Copy this directory, including the migrations directory, into your project. If you're feeling fancy you could use git-subtree or -submodules.
2. Set environment variables for `CONTENTFUL_SPACE`, `CONTENTFUL_ENVIRONMENT`, and `CONTENTFUL_MANAGEMENT_KEY`. The management key should be a Personal Access Token, which you can recognize because it will start with `CFPAT-`.
3. Run `./migrate.sh initialize` to create the `migrations` content type in your Contentful environment. This is how we track which migrations have been applied.
4. If you want to have typescript autocomplete in your editor, run `npm install` to pull in the types
5. Set up your continuous deployment server to run `./migrate.sh migrate`.

### Contentful setup assumptions

- Each deployed stage of your application has its own Contentful environment.
- Developers who are working on content model changes can use an isolated Contentful environment.

### Usage

1. When you need to do a migration, create a file with `./migrate.sh new <filename>`.
2. Edit the new migration file that is created. Commit it to your branch.
3. When your branch reaches a deployed stage, your CI/CD server should run the migration against the contentful environment associated with that stage.

### Vocab

- a _Space_ is what Contentful calls a project or property. There's only one associated with this project.
- _Environments_. There’s one “master” environment, which is the only one actually cached. That's what we use for production. We have another special environment, called "dev", used for the dev server. We create a new environment when a feature branch requires contentful schema changes. Each environment has independent data, including content models, but when you make a new one it always starts off with everything in "master".
- _Content model_. Think of this like a db schema for the stuff you’re storing in contentful. What fields are available, which are required, etc.

### Why we need migrations

Some CMSs don't support migrations. The schema and articles all live in the same database and the only way to push changes up is to either
1. click around in the interface, or
2. completely replace the production data with your local stuff.

The workflow in those situations is:
1. Clone down the prod db. Tell any content editors to stop using the site for a couple days while you work.
2. Make changes to the data model, possibly backfilling articles with new fields, etc.
3. Replace the prod db with the changed db from your local computer.
4. Tell the content editors it's okay to use the site again.

For many sites, that level of coordination with the editors is unacceptable. Imagine a daily newspaper that couldn't publish any new articles (or even work on drafts!) because the devs were working on adding a field to the content model.

Migrations allow us to describe how to adjust the data model of an existing database, rather than replacing it entirely and blowing away any content changes since the data was cloned down.

### Workflow for changing content model

Some changes to the website will require changing the structure of the data. Contentful allows you to try these changes out in a segregated environment, then script the changes so they are applied at the same time as the code you needed them for.

I’m only just learning about this stuff, so treat these as guidelines more than laws. Please update here as we learn things; I’m just basing the recommendations off of my database migration experience.

1. Make a new environment to try out your changes. `contentful space environment create --environment-id 'add-betting-field' --name 'add-betting-field'`. Using the db analogy, this is like a local database copy you can change without impacting anyone else.
2. Create a [migration script](https://www.contentful.com/developers/docs/tutorials/cli/scripting-migrations/) in the contentful-migrations directory: `contentful/migrate.sh new add-betting-field`. For example:

```js
// @ts-check

/**
 * @param {import("contentful-migration").default} migration
 */
 module.exports = function (migration) {
  const rules = migration.editContentType('rules');

  rules.createField('betting')
    .type('Boolean')
    .name('Do people sometimes play this for money?');

  // backfill existing data, using the gameType field
  // and assuming that only Casino games are betting games
  migration.transformEntries({
    contentType: 'rules',
    from: ['gameType'],
    to: ['betting'],
    transformEntryForLocale: (from, locale) => {
      return {
        betting: from.gameType[locale] === 'Casino',
      };
    }
  });
}
```

Migrations are committed to the repo, in this directory. They are applied in alphabetical order by file name, and only applied once for a given environment.

If you `npm install` in this directory your editor should give you typescript-style autocomplete in migration files.

3. Make whatever code changes you need. For example, the same branch that adds a `betting` field to a model might want to display it when it's present.
4. Once your code lands on dev or prod, the migration will be run automatically.

### Guidelines for writing migrations

**Migrations should be compatible with the production code running before and after they are applied.**

Migrations are in a branch are run before the new code from that branch is deployed. This means there's a small window where the migration has run, but the old code is still running. Don't break the site during this window. Considering that deploys can fail, the window of time may not be so small after all.

Some examples of safe changes:
- Make a new content type
- Add a non-required field to an existing content type
- Delete a field that has already been removed from the code (and those code changes are live).
- Remove all code references to a field, but leave the data in contentful.

Some examples of ⚠️_unsafe_⚠️ changes:
- Delete a field, removing code references in the same deploy. Instead, remove code references first, then delete the field.
- Rename a field. Instead:
  1. Create a new field, copying data from `oldFieldName` to `newFieldName` using `migration.transformEntries`.
  2. Update the code to look at either `newFieldName` or `oldFieldName`, using whichever is populated.
  3. Push those changes all the way to production.
  4. Mark the old field `omitted` and `disabled`.
  5. Use `migration.transformEntries` _again_, in case there were new entries created where the content editor didn't fill in the new field. Alternatively, spot check the data.
  6. delete the old field.

#### Further Reading

- Databases have been doing this stuff for a long time. Braintree (Paypal) published a great article about how they approach migrations in Postgresql: https://medium.com/paypal-tech/postgresql-at-scale-database-schema-changes-without-downtime-20d3749ed680.
- https://www.prisma.io/dataguide/types/relational/expand-and-contract-pattern
- Contentful has written about this at https://www.contentful.com/help/cms-as-code/

### Refreshing the dev environment

Sometimes, we'll merge some migrations to dev that end up not working, and we decide to go another way. After this has happened a few times, it's easy for the dev and prod environments to diverge. To fix this, delete the dev environment, and make a new one based on the one from prod.

As an extra benefit, you'll get a refreshed set of data copied down from prod.

### Resources

- Video demonstration of a handful of migration https://contentful.wistia.com/medias/kkw7k4j7lp
- [Contentful migration docs](https://github.com/contentful/contentful-migration#readme) have a bunch of example migration scripts and detail what methods are available

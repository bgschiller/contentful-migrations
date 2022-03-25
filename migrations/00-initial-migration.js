// @ts-check

/**
 * @param {import("contentful-migration").default} migration
 */
 module.exports = function (migration) {
  const migrations = migration
    .createContentType("migrations")
    .name("Migrations")
    .description(
      "Tracks content model migrations that have been applied at deploy time. These do not appear on the site. AVOID EDITING DIRECTLY!"
    )
    .displayField("name");

  migrations
    .createField("name")
    .name("name")
    .type("Symbol")
    .localized(false)
    .required(true);
  migrations
    .createField("appliedAt")
    .name("appliedAt")
    .type("Date")
    .localized(false)
    .required(true);
  migrations.changeFieldControl("name", "builtin", "singleLine", {});
  migrations.changeFieldControl("appliedAt", "builtin", "datePicker", {});
}

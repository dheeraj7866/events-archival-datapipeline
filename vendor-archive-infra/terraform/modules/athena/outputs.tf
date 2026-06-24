output "workgroup_name" { value = aws_athena_workgroup.vendor_archive.name }
output "glue_database" { value = aws_glue_catalog_database.vendor_archive.name }
output "glue_table" { value = aws_glue_catalog_table.vendor_events_cold.name }
output "results_bucket" { value = aws_s3_bucket.athena_results.id }

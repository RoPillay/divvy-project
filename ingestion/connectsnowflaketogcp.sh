gcloud iam roles create snowflakeReader \
  --project=$PROJECT_ID \
  --title="Snowflake bucket reader" \
  --permissions=storage.buckets.get,storage.objects.get,storage.objects.list


  gcloud storage buckets add-iam-policy-binding gs://$BUCKET \
  --member="serviceAccount:$SNOWFLAKE_SA" \
  --role="projects/$PROJECT_ID/roles/snowflakeReader"
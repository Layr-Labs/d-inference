package deps

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

type BucketClient struct {
	client   *s3.Client
	bucket   string
	endpoint string
}

func NewBucketClient(ctx context.Context, endpoint, bucket string) (*BucketClient, error) {
	cfg, err := config.LoadDefaultConfig(ctx,
		config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(
			"test", "test", "",
		)),
		config.WithRegion("us-east-1"),
	)
	if err != nil {
		return nil, fmt.Errorf("testbed/bucket: aws config: %w", err)
	}

	client := s3.NewFromConfig(cfg, func(o *s3.Options) {
		o.BaseEndpoint = aws.String(endpoint)
		o.UsePathStyle = true
	})

	_, err = client.CreateBucket(ctx, &s3.CreateBucketInput{
		Bucket: aws.String(bucket),
	})
	if err != nil {
		var alreadyOwned *types.BucketAlreadyExists
		var alreadyOwnedByYou *types.BucketAlreadyOwnedByYou
		if alreadyOwned == nil && alreadyOwnedByYou == nil {
			return nil, fmt.Errorf("testbed/bucket: create bucket: %w", err)
		}
	}

	return &BucketClient{
		client:   client,
		bucket:   bucket,
		endpoint: endpoint,
	}, nil
}

func (bc *BucketClient) PutObject(ctx context.Context, key string, data []byte) error {
	_, err := bc.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket: aws.String(bc.bucket),
		Key:    aws.String(key),
		Body:   bytes.NewReader(data),
	})
	return err
}

func (bc *BucketClient) PutFile(ctx context.Context, key, filePath string) error {
	f, err := os.Open(filePath)
	if err != nil {
		return fmt.Errorf("testbed/bucket: open %s: %w", filePath, err)
	}
	defer f.Close()

	_, err = bc.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket: aws.String(bc.bucket),
		Key:    aws.String(key),
		Body:   f,
	})
	return err
}

func (bc *BucketClient) PutReader(ctx context.Context, key string, r io.Reader) error {
	_, err := bc.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket: aws.String(bc.bucket),
		Key:    aws.String(key),
		Body:   r,
	})
	return err
}

func (bc *BucketClient) CDNURL() string {
	return fmt.Sprintf("%s/%s", bc.endpoint, bc.bucket)
}
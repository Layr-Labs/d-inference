package aliaspolicy

import (
	modelmeta "github.com/eigeninference/d-inference/coordinator/internal/api/catalog/metadata"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func ConcreteModelEligibleForOpenRouterFeed(
	modelID string,
	catalogByID map[string]store.SupportedModel,
	aggregateTypeByID map[string]string,
) bool {
	catalogModel, ok := catalogByID[modelID]
	if !ok {
		return false
	}
	modelType := catalogModel.ModelType
	if aggregateType, found := aggregateTypeByID[modelID]; found {
		modelType = aggregateType
	}
	return !modelmeta.IsNonTextModelType(modelType)
}

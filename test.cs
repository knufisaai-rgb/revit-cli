var walls = new FilteredElementCollector(Doc)
    .OfClass(typeof(Wall))
    .GetElementCount();
return $"벽 개수: {walls}개";
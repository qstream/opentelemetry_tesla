defmodule Tesla.Middleware.OpenTelemetry do
  alias OpenTelemetry.SemanticConventions
  require OpenTelemetry.Ctx
  require SemanticConventions.Trace

  @behaviour Tesla.Middleware

  @tracer_id __MODULE__

  @impl true
  def call(env, next, options) do
    span_name = get_span_name(env)
    span_continuation(options)
    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      span_name,
      %{},
      %{kind: :client}
    )

    result = Tesla.put_headers(env, :otel_propagator_text_map.inject([]))
    |> Tesla.run(next)
    |> set_span_attributes()
    |> handle_result()

    OpentelemetryTelemetry.end_telemetry_span(__MODULE__, %{})
    result
  end

  defp span_continuation(_options) do
    current_span_ctx = case OpentelemetryProcessPropagator.fetch_ctx(self()) do
      :undefined ->
        OpentelemetryProcessPropagator.fetch_parent_ctx(1, :"$callers")
      ctx ->
        ctx
    end
    case current_span_ctx do
      :undefined ->
        :ok
      ctx ->
        OpenTelemetry.Ctx.attach(ctx)
    end
  end

  defp get_span_name(env) do
    case env.opts[:path_params] do
      nil -> "HTTP #{http_method(env.method)}"
      _ -> URI.parse(env.url).path
    end
  end

  defp set_span_attributes({_, %Tesla.Env{} = env} = result) do
    OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, %{})
    OpenTelemetry.Tracer.set_attributes(build_attrs(env))

    result
  end

  defp set_span_attributes(result) do
    result
  end

  defp handle_result({:ok, %Tesla.Env{status: status} = env}) when status > 400 do
    OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, ""))

    {:ok, env}
  end

  defp handle_result({:error, {Tesla.Middleware.FollowRedirects, :too_many_redirects}} = result) do
    OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, ""))

    result
  end

  defp handle_result({:ok, env}) do
    {:ok, env}
  end

  defp handle_result(result) do
    OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, ""))

    result
  end

  defp build_attrs(%Tesla.Env{
         method: method,
         url: url,
         status: status_code,
         headers: headers,
         query: query
       }) do
    url = Tesla.build_url(url, query)
    uri = URI.parse(url)

    attrs = %{
      SemanticConventions.Trace.http_method() => http_method(method),
      SemanticConventions.Trace.http_url() => url,
      SemanticConventions.Trace.http_target() => uri.path,
      SemanticConventions.Trace.net_host_name() => uri.host,
      SemanticConventions.Trace.net_host_port() => uri.port,
      SemanticConventions.Trace.http_scheme() => uri.scheme,
      SemanticConventions.Trace.http_status_code() => status_code
    }

    maybe_append_content_length(attrs, headers)
  end

  defp maybe_append_content_length(attrs, headers) do
    case Enum.find(headers, fn {k, _v} -> k == "content-length" end) do
      nil ->
        attrs

      {_key, content_length} ->
        Map.put(attrs, SemanticConventions.Trace.http_response_content_length(), content_length)
    end
  end

  defp http_method(method) do
    method
    |> Atom.to_string()
    |> String.upcase()
  end
end

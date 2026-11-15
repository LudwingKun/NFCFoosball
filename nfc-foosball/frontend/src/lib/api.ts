import { FunctionsHttpError } from '@supabase/supabase-js'
import { supabase } from './supabase'

export type ApiError = Error & { status?: number }

export async function callApi<T>(action: string, params: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.functions.invoke('match-api', {
    body: { action, ...params },
  })
  if (error) {
    if (error instanceof FunctionsHttpError) {
      const body = await error.context.json()
      const err: ApiError = new Error(body.error ?? 'Request failed')
      err.status = error.context.status // lets pages tell 404 / 409 apart
      throw err
    }
    throw error
  }
  return data.data as T
}
